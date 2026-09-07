<#
.SYNOPSIS
    Reports drift between a locked VM's outbound allow ACLs and the addresses its
    allowlisted providers actually resolve to.

.DESCRIPTION
    Read-only. This script never changes an ACL, a VM, or the guest.

    One check runs per provider:

      * DNS coverage. Each provider hostname is resolved on the host and every
        returned address is tested against the union of the VM's outbound Allow
        ACLs. An address that no rule covers is drift: the guest would be able to
        resolve it (or have it pinned in /etc/hosts) and still be blocked.

    Nothing here is applied automatically. When drift is reported, enter
    maintenance mode and update the allowlist in Set-ClaudeVMNetworkMode.ps1 and
    the pinned entries in the guest /etc/hosts by hand.

.NOTES
    Cloudflare and CloudFront answer with a rotating subset of a larger pool, so a
    single resolution does not describe the whole pool. -DnsSamples queries more
    than once, but the Windows resolver cache may still collapse those samples
    into one answer. Treat a clean report as evidence about today's answer, not a
    guarantee about the pool.
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("all", "claude", "codex")]
    [string]$Provider = "all",

    [Parameter(Mandatory = $false)]
    [string]$VMName = "claude-base",

    [Parameter(Mandatory = $false)]
    [string]$AdapterName = "",

    [Parameter(Mandatory = $false)]
    [int]$DnsSamples = 3,

    # Exit 1 when drift is found, for use from a scheduled task.
    [Parameter(Mandatory = $false)]
    [switch]$FailOnDrift
)

$ErrorActionPreference = "Stop"

$Providers = [ordered]@{
    claude = @{
        Label     = "Claude / Anthropic"
        Hostnames = @(
            "api.anthropic.com",
            "platform.claude.com",
            "claude.ai",
            # Managed MCP connectors are proxied through Anthropic rather than
            # connecting to the provider directly, so this must resolve too.
            "mcp-proxy.anthropic.com"
        )
        Note      = ""
    }
    codex = @{
        Label     = "Codex / OpenAI"
        Hostnames = @("api.openai.com", "auth.openai.com")
        Note      = "Cloudflare anycast. Addresses rotate; the guest only ever uses the address pinned in /etc/hosts."
    }
}

function ConvertTo-UInt32Address {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    $parsed = [System.Net.IPAddress]::Parse($Address)

    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Not an IPv4 address: $Address"
    }

    $bytes = $parsed.GetAddressBytes()

    return ([uint32]$bytes[0] -shl 24) -bor
           ([uint32]$bytes[1] -shl 16) -bor
           ([uint32]$bytes[2] -shl 8)  -bor
           ([uint32]$bytes[3])
}

function ConvertTo-IpRange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cidr
    )

    # A bare address and an explicit /32 mean the same thing. Hyper-V reports the
    # remote address either way, so both forms have to parse.
    $text   = $Cidr.Trim()
    $prefix = 32

    if ($text -match "^(.+)/(\d+)$") {
        $text   = $Matches[1]
        $prefix = [int]$Matches[2]
    }

    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid IPv4 prefix length in: $Cidr"
    }

    $base = ConvertTo-UInt32Address -Address $text

    if ($prefix -eq 0) {
        $size = [uint64]4294967296
    }
    else {
        $size = [uint64][System.Math]::Pow(2, 32 - $prefix)
    }

    # Modulo rather than a bitwise mask: -bnot on a uint64 can widen to a signed
    # value in Windows PowerShell and silently produce a negative base.
    $baseValue = [uint64]$base
    $start     = $baseValue - ($baseValue % $size)

    return [PSCustomObject]@{
        Start = $start
        End   = $start + $size - 1
        Cidr  = $Cidr
    }
}

function Get-CoveringRule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $false)]
        [object[]]$Rule = @()
    )

    $value = ConvertTo-UInt32Address -Address $Address

    foreach ($item in $Rule) {
        if ($value -ge $item.Start -and $value -le $item.End) {
            return $item.Cidr
        }
    }

    return $null
}

function Get-AllowedRange {
    if ([string]::IsNullOrWhiteSpace($AdapterName)) {
        $script:AdapterName = (Get-VMNetworkAdapter -VMName $VMName).Name
    }

    $acls = Get-VMNetworkAdapterAcl `
        -VMName $VMName `
        -VMNetworkAdapterName $AdapterName

    $ranges = @()

    foreach ($acl in $acls) {
        if ($acl.Direction -ne "Outbound" -or $acl.Action -ne "Allow") {
            continue
        }

        $property = $acl.PSObject.Properties["RemoteAddress"]

        if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Could not read the remote address of a VM network adapter ACL on $VMName ($AdapterName). Drift cannot be reported against unknown ACL state."
        }

        $address = ([string]$property.Value).Trim()

        # IPv6 allow rules are out of scope: the allowlist is IPv4 only and locked
        # mode denies ::/0 outright.
        if ($address -match ":") {
            continue
        }

        $ranges += (ConvertTo-IpRange -Cidr $address)
    }

    return @($ranges)
}

function Resolve-HostAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )

    $found = @()

    for ($i = 0; $i -lt [System.Math]::Max(1, $DnsSamples); $i++) {
        try {
            $records = Resolve-DnsName -Name $Hostname -Type A -DnsOnly -ErrorAction Stop
        }
        catch {
            Write-Warning "  Could not resolve $Hostname : $($_.Exception.Message)"
            return @()
        }

        foreach ($record in $records) {
            if ($record.Type -eq "A" -and -not [string]::IsNullOrWhiteSpace($record.IPAddress)) {
                $found += $record.IPAddress
            }
        }
    }

    return @($found | Select-Object -Unique | Sort-Object)
}

# --- Report ---------------------------------------------------------------

$allowRules = Get-AllowedRange

if ($allowRules.Count -eq 0) {
    throw "No outbound Allow ACLs found on $VMName ($AdapterName). The VM may be in maintenance mode, in which case drift cannot be assessed."
}

Write-Host ""
Write-Host "IP / ACL drift report"
Write-Host "  VM:      $VMName ($AdapterName)"
Write-Host "  Rules:   $($allowRules.Count) outbound allow"
Write-Host "  Sampled: $DnsSamples DNS queries per hostname"

$selected = @()

if ($Provider -eq "all") {
    $selected = @($Providers.Keys)
}
else {
    $selected = @($Provider)
}

$driftFound = $false

foreach ($key in $selected) {
    $entry = $Providers[$key]

    $hostnames = @($entry.Hostnames)

    Write-Host ""
    Write-Host $entry.Label

    if (-not [string]::IsNullOrWhiteSpace($entry.Note)) {
        Write-Host "  note: $($entry.Note)"
    }

    $results  = @()
    $resolved = 0

    foreach ($hostname in $hostnames) {
        foreach ($address in (Resolve-HostAddress -Hostname $hostname)) {
            $resolved++

            $results += [PSCustomObject]@{
                Hostname = $hostname
                Address  = $address
                Rule     = (Get-CoveringRule -Address $address -Rule $allowRules)
            }
        }
    }

    if ($resolved -eq 0) {
        Write-Host "  no addresses resolved, nothing to compare"
        continue
    }

    $covered = @($results | Where-Object { $null -ne $_.Rule })

    # A provider with nothing covered is a provider that is switched off, not a
    # provider that has drifted. Reporting every address as drift in that state
    # would train the reader to ignore this report.
    if ($covered.Count -eq 0) {
        Write-Host "  not currently allowlisted (toggled off?)"

        foreach ($item in $results) {
            Write-Host ("    {0,-26} {1,-16} -" -f $item.Hostname, $item.Address)
        }

        continue
    }

    foreach ($item in $results) {
        if ($null -ne $item.Rule) {
            Write-Host ("  {0,-26} {1,-16} OK    ({2})" -f $item.Hostname, $item.Address, $item.Rule)
        }
        else {
            $driftFound = $true
            Write-Warning ("  {0,-26} {1,-16} DRIFT no allow rule covers this address" -f $item.Hostname, $item.Address)
        }
    }

    if (@($results | Where-Object { $null -eq $_.Rule }).Count -gt 0) {
        Write-Warning "  Action: if you re-pin any DRIFT address in the guest /etc/hosts, add it to the allowlist first."
    }

}

Write-Host ""

if ($driftFound) {
    Write-Warning "Drift detected. Nothing was changed automatically."

    if ($FailOnDrift) {
        exit 1
    }
}
else {
    Write-Host "No drift detected."
}
