param(
    [Parameter(Mandatory = $false)]
    [string]$Name = "",

    [Parameter(Mandatory = $false)]
    [int]$MemoryGB = 4,

    [Parameter(Mandatory = $false)]
    [int]$CpuCount = 2,

    [Parameter(Mandatory = $false)]
    [switch]$Maintenance,

    # Forwarded to the lock script. Off unless asked for.
    [Parameter(Mandatory = $false)]
    [switch]$Atlassian
)

$ErrorActionPreference = "Stop"

$TemplateDisk      = "C:\VMs\templates\claude-base-template.vhdx"
$SwitchName        = "fresh-claude-switch"
$Root              = "C:\VMs\ephemeral"
$DiskDir           = "$Root\disks"
$VmRootDir         = "$Root\vms"
$NetworkModeScript = "C:\VMs\Set-ClaudeVmNetworkMode.ps1"

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

if (-not (Get-NetIPAddress -InterfaceAlias $SwitchAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostIP })) {
    throw "Missing required switch IP: $HostIP/24 on $SwitchAlias"
}

if (-not (Test-Path $TemplateDisk)) {
    throw "Template disk not found: $TemplateDisk"
}

if (-not (Test-Path $NetworkModeScript)) {
    throw "Network mode script not found: $NetworkModeScript"
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch not found: $SwitchName"
}

if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = "claude-ephemeral-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
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

Set-VM `
    -Name $Name `
    -CheckpointType Disabled

Set-VMFirmware `
    -VMName $Name `
    -EnableSecureBoot On `
    -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

$BootDisk = Get-VMHardDiskDrive -VMName $Name

Set-VMFirmware `
    -VMName $Name `
    -FirstBootDevice $BootDisk

$Adapter = (Get-VMNetworkAdapter -VMName $Name).Name

if ($Maintenance) {
    Write-Host "Maintenance mode requested: no outbound deny will be applied."
}
else {
    Write-Host "Applying locked outbound ACL policy..."

    & $NetworkModeScript `
        -Mode locked `
        -VMName $Name `
        -AdapterName $Adapter `
        -SwitchName $SwitchName `
        -Atlassian:$Atlassian
}

Start-VM -Name $Name

Write-Host ""
Write-Host "Started ephemeral VM: $Name"
Write-Host ""
Write-Host "Network ACLs:"
Get-VMNetworkAdapterAcl -VMName $Name -VMNetworkAdapterName $Adapter
Write-Host ""
Write-Host "Destroy with:"
Write-Host "  C:\VMs\Remove-ClaudeEphemeral.ps1 -Name $Name"