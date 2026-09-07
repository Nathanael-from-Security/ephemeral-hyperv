<#
.SYNOPSIS
    Reports drift between a locked VM's outbound allow ACLs and the addresses its
    allowlisted providers actually resolve to.

.DESCRIPTION
    Read-only. This script never changes an ACL, a VM, or the guest.

    Two checks run per provider:

      * DNS coverage. Each provider hostname is resolved on the host and every
        returned address is tested against the union of the VM's outbound Allow
        ACLs. An address that no rule covers is drift: the guest would be able to
        resolve it (or have it pinned in /etc/hosts) and still be blocked.

      * Feed coverage. Only Atlassian publishes a machine readable ingress feed.
        Anthropic and OpenAI publish egress ranges only, which are the addresses
        their servers call out from, not the addresses their API hostnames answer
        on, so DNS is the only usable signal for those two.

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
    [ValidateSet("all", "claude", "codex", "atlassian")]
    [string]$Provider = "all",

    [Parameter(Mandatory = $false)]
    [string]$VMName = "claude-base",

    [Parameter(Mandatory = $false)]
    [string]$AdapterName = "",

    [Parameter(Mandatory = $false)]
    [int]$DnsSamples = 3,

    # Tenant specific, so it cannot be hardcoded. Example: -AtlassianSite totara
    [Parameter(Mandatory = $false)]
    [string]$AtlassianSite = "",

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
        Feed      = $null
        Note      = ""
    }
    codex = @{
        Label     = "Codex / OpenAI"
        Hostnames = @("api.openai.com", "auth.openai.com")
        Feed      = $null
        Note      = "Cloudflare anycast. Addresses rotate; the guest only ever uses the address pinned in /etc/hosts."
    }
    atlassian = @{
        Label     = "Atlassian Cloud"
        Hostnames = @(
            "mcp.atlassian.com",
            "api.atlassian.com",
            "id.atlassian.com",
            "auth.atlassian.com"
        )
        Feed      = "https://ip-ranges.atlassian.com/"
        Note      = "mcp.atlassian.com is in Atlassian's own space; the rest are CloudFront backed. One pinned address will not serve all of them."
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

function Merge-IpRange {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Range = @()
    )

    # Coverage is tested against the union of every allow rule, not against rules
    # one at a time, so two adjacent CIDRs cover a block that spans both.
    $merged = @()

    foreach ($item in @($Range | Sort-Object Start, End)) {
        if ($merged.Count -eq 0) {
            $merged += [PSCustomObject]@{ Start = $item.Start; End = $item.End }
            continue
        }

        $last = $merged[$merged.Count - 1]

        if ($item.Start -le $last.End + 1) {
            if ($item.End -gt $last.End) {
                $last.End = $item.End
            }
        }
        else {
            $merged += [PSCustomObject]@{ Start = $item.Start; End = $item.End }
        }
    }

    return @($merged)
}

function Test-RangeCovered {
    param(
        [Parameter(Mandatory = $true)]
        $Range,

        [Parameter(Mandatory = $false)]
        [object[]]$Merged = @()
    )

    foreach ($block in $Merged) {
        if ($Range.Start -ge $block.Start -and $Range.End -le $block.End) {
            return $true
        }
    }

    return $false
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

function Get-AtlassianPublishedCidr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Feed
    )

    try {
        $json = Invoke-RestMethod -Uri $Feed -UseBasicParsing -TimeoutSec 20
    }
    catch {
        Write-Warning "  Could not fetch $Feed : $($_.Exception.Message)"
        Write-Warning "  Feed comparison skipped. DNS results below are still valid."
        return $null
    }

    $cidrs = @(
        $json.items |
            Where-Object {
                $_.direction -contains "ingress" -and
                $_.perimeter -eq "commercial" -and
                $_.product -contains "jira" -and
                $_.cidr -notmatch ":"
            } |
            Select-Object -ExpandProperty cidr -Unique
    )

    if ($cidrs.Count -eq 0) {
        Write-Warning "  Feed returned no matching IPv4 ingress CIDRs. The upstream schema may have changed."
        return $null
    }

    return [PSCustomObject]@{
        Cidrs        = $cidrs
        CreationDate = $json.creationDate
    }
}

# --- Report ---------------------------------------------------------------

$allowRules = Get-AllowedRange

if ($allowRules.Count -eq 0) {
    throw "No outbound Allow ACLs found on $VMName ($AdapterName). The VM may be in maintenance mode, in which case drift cannot be assessed."
}

$allowMerged = @(Merge-IpRange -Range $allowRules)

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

    if ($key -eq "atlassian" -and -not [string]::IsNullOrWhiteSpace($AtlassianSite)) {
        $hostnames += "$AtlassianSite.atlassian.net"
    }

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

    if ([string]::IsNullOrWhiteSpace($entry.Feed)) {
        continue
    }

    $published = Get-AtlassianPublishedCidr -Feed $entry.Feed

    if ($null -eq $published) {
        continue
    }

    $publishedRanges = @($published.Cidrs | ForEach-Object { ConvertTo-IpRange -Cidr $_ })
    $publishedMerged = @(Merge-IpRange -Range $publishedRanges)

    # Compared by address coverage rather than by CIDR string. The raw feed
    # publishes a /21 alongside its own constituent /24s, so string comparison
    # against a collapsed allowlist would report drift on every single run.
    $missing = @($publishedRanges | Where-Object { -not (Test-RangeCovered -Range $_ -Merged $allowMerged) })

    $stale = @()

    # Only allow rules that overlap published Atlassian space are candidates for
    # removal. Claude, Codex and the host rule must never be reported here.
    foreach ($rule in $allowRules) {
        $overlaps = $false

        foreach ($block in $publishedMerged) {
            if ($rule.Start -le $block.End -and $rule.End -ge $block.Start) {
                $overlaps = $true
                break
            }
        }

        if ($overlaps -and -not (Test-RangeCovered -Range $rule -Merged $publishedMerged)) {
            $stale += $rule
        }
    }

    if ($missing.Count -eq 0 -and $stale.Count -eq 0) {
        Write-Host "  feed: matches the applied allowlist (published $($published.CreationDate))"
        continue
    }

    $driftFound = $true

    Write-Warning "  ATLASSIAN IP RANGES HAVE CHANGED (published $($published.CreationDate))"

    if ($missing.Count -gt 0) {
        Write-Warning "    published but NOT allowlisted, add these:"

        foreach ($item in ($missing | Sort-Object Start)) {
            Write-Warning "      $($item.Cidr)"
        }
    }

    if ($stale.Count -gt 0) {
        Write-Warning "    allowlisted but no longer published, consider removing:"

        foreach ($item in ($stale | Sort-Object Start)) {
            Write-Warning "      $($item.Cidr)"
        }
    }

    Write-Warning "    Action: enter maintenance mode, update `$AtlassianAllowlist in"
    Write-Warning "    Set-ClaudeVMNetworkMode.ps1 and the guest /etc/hosts pins, then re-lock."
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
