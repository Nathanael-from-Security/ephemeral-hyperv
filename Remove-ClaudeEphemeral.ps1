param(
    [Parameter(Mandatory = $true)]
    [string]$Name
)

$ErrorActionPreference = "Stop"

$Root     = "C:\VMs\ephemeral"
$DiskDir  = "$Root\disks"
$VmRootDir = "$Root\vms"

$DiffDisk = Join-Path $DiskDir "$Name.vhdx"
$VmDir    = Join-Path $VmRootDir $Name

Write-Host "Destroying ephemeral VM: $Name"
Write-Host ""

$VM = Get-VM -Name $Name -ErrorAction SilentlyContinue

if ($VM) {
    if ($VM.State -ne "Off") {
        Write-Host "Stopping VM..."
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Removing VM registration..."
    Remove-VM -Name $Name -Force
} else {
    Write-Host "VM not found in Hyper-V. Continuing cleanup..."
}

if (Test-Path $DiffDisk) {
    Write-Host "Deleting differencing disk: $DiffDisk"
    Remove-Item -Path $DiffDisk -Force
} else {
    Write-Host "Differencing disk not found: $DiffDisk"
}

if (Test-Path $VmDir) {
    Write-Host "Deleting VM folder: $VmDir"
    Remove-Item -Path $VmDir -Recurse -Force
} else {
    Write-Host "VM folder not found: $VmDir"
}

Write-Host ""
Write-Host "Destroyed ephemeral VM: $Name"