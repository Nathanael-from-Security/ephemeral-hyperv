param(
    [Parameter(Mandatory = $false)]
    [string]$Name = "",

    [Parameter(Mandatory = $false)]
    [int]$MemoryGB = 4,

    [Parameter(Mandatory = $false)]
    [int]$CpuCount = 2,

    [Parameter(Mandatory = $false)]
    [switch]$Maintenance
)

$ErrorActionPreference = "Stop"

$TemplateDisk = "C:\VMs\templates\claude-base-template.vhdx"
$SwitchName   = "fresh-claude-switch"
$Root         = "C:\VMs\ephemeral"
$DiskDir      = "$Root\disks"
$VmRootDir    = "$Root\vms"

$HostIP       = "172.30.101.1"
$ClaudeAPI    = "160.79.104.0/21"

if (-not (Test-Path $TemplateDisk)) {
    throw "Template disk not found: $TemplateDisk"
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch not found: $SwitchName"
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Name = "claude-ephemeral-$Stamp"
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "A VM already exists with this name: $Name"
}

New-Item -ItemType Directory -Force -Path $DiskDir, $VmRootDir | Out-Null

$VmDir    = Join-Path $VmRootDir $Name
$DiffDisk = Join-Path $DiskDir "$Name.vhdx"

if (Test-Path $DiffDisk) {
    throw "Differencing disk already exists: $DiffDisk"
}

Write-Host "Creating ephemeral VM: $Name"
Write-Host "Template disk: $TemplateDisk"
Write-Host "Differencing disk: $DiffDisk"
Write-Host ""

New-Item -ItemType Directory -Force -Path $VmDir | Out-Null

New-VHD `
    -Path $DiffDisk `
    -ParentPath $TemplateDisk `
    -Differencing | Out-Null

New-VM `
    -Name $Name `
    -Generation 2 `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -VHDPath $DiffDisk `
    -SwitchName $SwitchName `
    -Path $VmDir | Out-Null

Set-VMProcessor `
    -VMName $Name `
    -Count $CpuCount

Set-VMMemory `
    -VMName $Name `
    -DynamicMemoryEnabled $true `
    -MinimumBytes 2GB `
    -StartupBytes ($MemoryGB * 1GB) `
    -MaximumBytes 8GB

# Disable checkpoints for ephemeral VMs.
Set-VM `
    -Name $Name `
    -CheckpointType Disabled

$Adapter = (Get-VMNetworkAdapter -VMName $Name).Name

if ($Maintenance) {
    Write-Host "Maintenance mode requested: no outbound deny will be applied."
} else {
    Write-Host "Applying locked outbound ACL policy..."

    Add-VMNetworkAdapterAcl `
        -VMName $Name `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress "$HostIP/32" `
        -Direction Outbound `
        -Action Allow

    Add-VMNetworkAdapterAcl `
        -VMName $Name `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress $ClaudeAPI `
        -Direction Outbound `
        -Action Allow

    Add-VMNetworkAdapterAcl `
        -VMName $Name `
        -VMNetworkAdapterName $Adapter `
        -RemoteIPAddress "0.0.0.0/0" `
        -Direction Outbound `
        -Action Deny
}

Set-VMFirmware `
    -VMName $Name `
    -EnableSecureBoot On `
    -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

$BootDisk = Get-VMHardDiskDrive -VMName $Name

Set-VMFirmware `
    -VMName $Name `
    -FirstBootDevice $BootDisk

Start-VM -Name $Name

Write-Host ""
Write-Host "Started ephemeral VM: $Name"
Write-Host ""
Write-Host "Network ACLs:"
Get-VMNetworkAdapterAcl -VMName $Name -VMNetworkAdapterName $Adapter
Write-Host ""
Write-Host "Destroy with:"
Write-Host "  C:\VMs\Remove-ClaudeEphemeral.ps1 -Name $Name"