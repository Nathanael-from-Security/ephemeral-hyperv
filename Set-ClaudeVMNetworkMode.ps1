param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("locked", "maintenance", "status")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$VMName = "claude-base",

    [Parameter(Mandatory = $false)]
    [string]$AdapterName = "",

    [Parameter(Mandatory = $false)]
    [string]$SwitchName = "fresh-claude-switch"
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
    "160.79.104.0/21",    # Claude API
    "104.18.41.241/32",   # OpenAI/Auth
    "162.159.140.245/32",
    "172.64.146.15/32",
    "172.66.0.243/32"
)

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

        $remainingDeny = @(Get-MatchingAcls -IP "0.0.0.0/0" -Action Deny)

        if ($remainingDeny.Count -gt 0) {
            Write-Host ""
            Show-Acls
            throw "Failed to remove the outbound 0.0.0.0/0 Deny ACL from $VMName ($AdapterName). The VM is still network locked."
        }

        Write-Host ""
        Write-Host "Maintenance mode active. VM can use general outbound internet."
        Write-Host ""

        Show-Acls
    }

    "locked" {
        Write-Host "Restoring locked mode for VM: $VMName"

        foreach ($ip in $Allowlist) {
            Set-Acl -IP $ip -Action Allow
        }

        Set-Acl -IP "0.0.0.0/0" -Action Deny

        Write-Host ""
        Write-Host "Locked mode active. VM outbound is limited to host + Claude/OpenAI API ranges."
        Write-Host ""

        Show-Acls
    }

    "status" {
        Show-Acls
    }
}