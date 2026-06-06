param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("locked", "maintenance", "status")]
    [string]$Mode
)

$VM        = "claude-base"
$Adapter   = "fresh-claude-adapter"
$HostIP    = "172.30.101.1"
$ClaudeAPI = "160.79.104.0/21"

function Remove-Rule {
    param(
        [string]$RemoteIPAddress,
        [string]$Direction,
        [string]$Action
    )

    Remove-VMNetworkAdapterAcl `
        -VMName $VM `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress $RemoteIPAddress `
        -Direction $Direction `
        -Action $Action `
        -ErrorAction SilentlyContinue
}

function Show-Rules {
    Get-VMNetworkAdapterAcl `
        -VMName $VM `
        -VMNetworkAdapterName $Adapter
}

if ($Mode -eq "maintenance") {
    Write-Host "Entering maintenance mode: removing default outbound deny..."

    Remove-Rule -RemoteIPAddress "0.0.0.0/0" -Direction Outbound -Action Deny

    Write-Host ""
    Write-Host "Maintenance mode active. VM can use general outbound internet."
    Write-Host "Run this when finished:"
    Write-Host "  C:\VMs\ClaudeSandbox.ps1 locked"
    Write-Host ""

    Show-Rules
    exit
}

if ($Mode -eq "locked") {
    Write-Host "Restoring locked mode..."

    # Remove known rules to avoid duplicates.
    Remove-Rule -RemoteIPAddress "$HostIP/32"     -Direction Outbound -Action Allow
    Remove-Rule -RemoteIPAddress $HostIP          -Direction Outbound -Action Allow
    Remove-Rule -RemoteIPAddress $ClaudeAPI       -Direction Outbound -Action Allow
    Remove-Rule -RemoteIPAddress "0.0.0.0/0"      -Direction Outbound -Action Deny

    # Re-add clean locked policy.
    Add-VMNetworkAdapterAcl `
        -VMName $VM `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress "$HostIP/32" `
        -Direction Outbound `
        -Action Allow

    Add-VMNetworkAdapterAcl `
        -VMName $VM `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress $ClaudeAPI `
        -Direction Outbound `
        -Action Allow

    Add-VMNetworkAdapterAcl `
        -VMName $VM `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress "0.0.0.0/0" `
        -Direction Outbound `
        -Action Deny

    Write-Host ""
    Write-Host "Locked mode active. VM outbound is limited to host + Claude API range."
    Write-Host ""

    Show-Rules
    exit
}

if ($Mode -eq "status") {
    Show-Rules
    exit
}