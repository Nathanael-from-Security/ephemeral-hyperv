param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("locked", "maintenance", "status")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$VMName = "claude-base",

    [Parameter(Mandatory = $false)]
    [string]$AdapterName = "",

    [Parameter(Mandatory = $false)]
    [string]$SwitchName = "fresh-claude-switch",

    # PLACEHOLDER. Accepted and warned about, but applies no rules.
    # Atlassian Cloud is reached through mcp-proxy.anthropic.com, which already
    # falls inside the Claude range, so no Atlassian CIDRs are needed. Kept so
    # existing invocations do not break and so the reason stays visible.
    [Parameter(Mandatory = $false)]
    [switch]$Atlassian
)

$ErrorActionPreference = "Stop"

$SwitchAlias = "vEthernet ($SwitchName)"

$HostIP = (
    Get-NetIPAddress `
        -InterfaceAlias $SwitchAlias `
        -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike "169.254.*" -and
        $_.PrefixOrigin -ne "WellKnown"
    } |
    Select-Object -First 1 -ExpandProperty IPAddress
)

if ([string]::IsNullOrWhiteSpace($HostIP)) {
    throw "Could not determine host IP for $SwitchAlias"
}

if ([string]::IsNullOrWhiteSpace($AdapterName)) {
    $AdapterName = (Get-VMNetworkAdapter -VMName $VMName).Name
}

$Allowlist = @(
    "$HostIP/32",          # Host
    "160.79.104.0/21",     # Claude - api.anthropic.com, platform.claude.com, claude.ai
    "104.18.41.241/32",    # Codex - auth.openai.com
    "172.64.146.15/32",    # Codex - auth.openai.com
    "162.159.140.245/32",  # Codex - api.openai.com
    "172.66.0.243/32"      # Codex - api.openai.com
)

# The Atlassian ingress ranges that used to live here were removed once traffic
# was shown to reach Atlassian through mcp-proxy.anthropic.com rather than
# directly. Recover them from git history if direct REST or curl access to
# Atlassian is ever needed from the sandbox.

function Show-Acls {
    Get-VMNetworkAdapterAcl `
        -VMName $VMName `
        -VMNetworkAdapterName $AdapterName
}

function Get-AclAddressVariants {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    $variants = @($IP)

    if ($IP -match "^(.+)/32$") {
        $variants += $Matches[1]
    }
    elseif ($IP -match "^(.+)/0$") {
        $variants += $Matches[1]
    }
    elseif ($IP -match "^\d+\.\d+\.\d+\.\d+$") {
        $variants += "$IP/32"
    }

    return @($variants | Select-Object -Unique)
}

function Get-AclRemoteAddress {
    param(
        [Parameter(Mandatory = $true)]
        $Acl
    )

    $property = $Acl.PSObject.Properties["RemoteAddress"]

    if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return ([string]$property.Value).Trim()
    }

    throw "Could not read the remote address of a VM network adapter ACL on $VMName ($AdapterName). ACL state cannot be verified."
}

function Get-MatchingAcls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Allow", "Deny")]
        [string]$Action = "Allow"
    )

    $variants = Get-AclAddressVariants -IP $IP

    return @(
        Show-Acls |
            Where-Object {
                $_.Direction -eq "Outbound" -and
                $_.Action -eq $Action -and
                $variants -contains (Get-AclRemoteAddress -Acl $_)
            }
    )
}

function Remove-Acl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Allow", "Deny")]
        [string]$Action = "Allow"
    )

    # Only rules that exist are removed, so a missing rule is not an error and
    # a failed removal is never swallowed.
    foreach ($existing in Get-MatchingAcls -IP $IP -Action $Action) {
        Remove-VMNetworkAdapterAcl `
            -VMName $VMName `
            -VMNetworkAdapterName $AdapterName `
            -RemoteIPAddress (Get-AclRemoteAddress -Acl $existing) `
            -Direction Outbound `
            -Action $Action `
            -ErrorAction Stop
    }
}

function Set-Acl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Allow", "Deny")]
        [string]$Action = "Allow"
    )

    Remove-Acl -IP $IP -Action $Action

    Add-VMNetworkAdapterAcl `
        -VMName $VMName `
        -VMNetworkAdapterName $AdapterName `
        -RemoteIPAddress $IP `
        -Direction Outbound `
        -Action $Action
}

switch ($Mode) {
    "maintenance" {
        Write-Host "Entering maintenance mode for VM: $VMName"

        Remove-Acl -IP "0.0.0.0/0" -Action Deny
        Remove-Acl -IP "::/0" -Action Deny

        $remainingDeny = @(Get-MatchingAcls -IP "0.0.0.0/0" -Action Deny) +
                         @(Get-MatchingAcls -IP "::/0" -Action Deny)

        if ($remainingDeny.Count -gt 0) {
            Write-Host ""
            Show-Acls
            throw "Failed to remove an outbound Deny ACL from $VMName ($AdapterName). The VM is still network locked."
        }

        Write-Host ""
        Write-Host "Maintenance mode active. VM can use general outbound internet."
        Write-Host ""

        Show-Acls
    }

    "locked" {
        Write-Host "Restoring locked mode for VM: $VMName"

        $desired = @($Allowlist)

        if ($Atlassian) {
            # A switch that silently does nothing is a trap, so say so plainly.
            Write-Warning "-Atlassian is a placeholder and applies no rules. Atlassian is reached through mcp-proxy.anthropic.com, inside the Claude range."
        }

        # Locked mode owns the whole set of outbound Allow rules, so anything not
        # in $desired is stale and has to go. This is what removes the Atlassian
        # rules left behind by an earlier version of this script.
        $desiredVariants = @(
            $desired | ForEach-Object { Get-AclAddressVariants -IP $_ }
        )

        $currentAllows = @(
            Show-Acls |
                Where-Object {
                    $_.Direction -eq "Outbound" -and
                    $_.Action -eq "Allow"
                }
        )

        foreach ($acl in $currentAllows) {
            $address = Get-AclRemoteAddress -Acl $acl

            if ($desiredVariants -notcontains $address) {
                Write-Host "Removing stale allow rule: $address"
                Remove-Acl -IP $address -Action Allow
            }
        }

        foreach ($ip in $desired) {
            Set-Acl -IP $ip -Action Allow
        }

        Set-Acl -IP "0.0.0.0/0" -Action Deny

        # The IPv4 deny says nothing about IPv6. Without this the guest would be
        # unconstrained over IPv6 the moment it ever acquired an address.
        Set-Acl -IP "::/0" -Action Deny

        Write-Host ""

        Write-Host "Locked mode active. VM outbound is limited to host + Claude/Codex API ranges."

        Write-Host ""

        Show-Acls

        # Advisory only. A drift report must never stop the VM from locking, so a
        # missing or failing checker is a warning and nothing more.
        $driftScript = Join-Path $PSScriptRoot "Test-IPACLDrift.ps1"

        if (Test-Path $driftScript) {
            try {
                & $driftScript -VMName $VMName -AdapterName $AdapterName
            }
            catch {
                Write-Warning "Drift check failed: $($_.Exception.Message)"
            }
        }
    }

    "status" {
        Show-Acls
    }
}