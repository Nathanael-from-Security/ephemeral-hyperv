[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseVmName = "claude-base",

    [string]$EphemeralVmNamePattern = "claude-ephemeral-*",

    [string]$BaseVhdPath = "C:\HyperV\claude-base\claude-base.vhdx",

    [string]$TemplateVhdPath = "C:\VMs\templates\claude-base-template.vhdx",

    [string]$NetworkScriptPath = "C:\VMs\Maintenance-ClaudeBase.ps1",

    [switch]$Force,

    [switch]$NoConnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message"
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[+] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Stop-VmCleanly {
    param(
        [Parameter(Mandatory)]
        [Microsoft.HyperV.PowerShell.VirtualMachine]$Vm,

        [int]$TimeoutSeconds = 120
    )

    if ($Vm.State -eq "Off") {
        Write-Ok "$($Vm.Name) is already off."
        return
    }

    Write-Step "Stopping VM: $($Vm.Name)"

    if ($PSCmdlet.ShouldProcess($Vm.Name, "Stop VM")) {
        Stop-VM -Name $Vm.Name -Force:$Force -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        do {
            Start-Sleep -Seconds 2
            $current = Get-VM -Name $Vm.Name
        } while ($current.State -ne "Off" -and (Get-Date) -lt $deadline)

        if ($current.State -ne "Off") {
            if ($Force) {
                Write-Warn "$($Vm.Name) did not stop cleanly. Forcing power off."
                Stop-VM -Name $Vm.Name -TurnOff -Force
            }
            else {
                throw "$($Vm.Name) did not stop within $TimeoutSeconds seconds. Re-run with -Force if you want to force power off."
            }
        }

        Write-Ok "$($Vm.Name) is off."
    }
}

Assert-Administrator

Write-Step "Checking Hyper-V state..."

$baseVm = Get-VM -Name $BaseVmName -ErrorAction Stop

$ephemeralVms = @(
    Get-VM |
        Where-Object {
            $_.Name -like $EphemeralVmNamePattern -and
            $_.State -ne "Off"
        }
)

if ($ephemeralVms.Count -gt 0) {
    Write-Step "Found active ephemeral VM(s):"
    $ephemeralVms | Select-Object Name, State | Format-Table -AutoSize

    foreach ($vm in $ephemeralVms) {
        Stop-VmCleanly -Vm $vm
    }
}
else {
    Write-Ok "No active ephemeral VMs found."
}

Write-Step "Ensuring base VM is stopped before changing disk attributes..."
Stop-VmCleanly -Vm $baseVm

Write-Step "Checking VHD paths..."

if (-not (Test-Path $BaseVhdPath)) {
    throw "Base VHDX not found: $BaseVhdPath"
}

if (Test-Path $TemplateVhdPath) {
    Write-Step "Setting template VHDX read/write: $TemplateVhdPath"

    if ($PSCmdlet.ShouldProcess($TemplateVhdPath, "Set read/write")) {
        Set-ItemProperty -Path $TemplateVhdPath -Name IsReadOnly -Value $false
    }

    Write-Ok "Template VHDX is read/write."
}
else {
    Write-Warn "Template VHDX not found. Skipping template attribute change: $TemplateVhdPath"
}

Write-Step "Setting base VHDX read/write: $BaseVhdPath"

if ($PSCmdlet.ShouldProcess($BaseVhdPath, "Set read/write")) {
    Set-ItemProperty -Path $BaseVhdPath -Name IsReadOnly -Value $false
}

Write-Ok "Base VHDX is read/write."

Write-Step "Starting base VM: $BaseVmName"

if ($PSCmdlet.ShouldProcess($BaseVmName, "Start VM")) {
    Start-VM -Name $BaseVmName
}

Write-Ok "Base VM started."

Write-Step "Switching base VM networking to maintenance mode..."

if (Test-Path $NetworkScriptPath) {
    if ($PSCmdlet.ShouldProcess($NetworkScriptPath, "Enable maintenance networking")) {
        & $NetworkScriptPath -Mode maintenance
    }

    Write-Ok "Maintenance networking enabled."
}
else {
    Write-Warn "Network control script not found. Skipping: $NetworkScriptPath"
}

if (-not $NoConnect) {
    Write-Step "Opening VM console..."

    if ($PSCmdlet.ShouldProcess($BaseVmName, "Open vmconnect")) {
        Start-Process vmconnect.exe -ArgumentList "localhost", $BaseVmName
    }
}

Write-Host ""
Write-Ok "Base image is ready for maintenance."
Write-Host ""
Write-Host "After updating the base VM, shut it down cleanly, re-lock networking, and rebuild the template:"
Write-Host ""
Write-Host "    Stop-VM -Name `"$BaseVmName`""
Write-Host "    while ((Get-VM -Name `"$BaseVmName`\").State -ne `"Off`\") { Start-Sleep -Seconds 2 }"
Write-Host "    & `"$NetworkScriptPath`" -Mode locked"
Write-Host ""
Write-Host "    `$template = `"$TemplateVhdPath`""
Write-Host "    `$source   = `"$BaseVhdPath`""
Write-Host "    if (Test-Path `$template) {"
Write-Host "        Set-ItemProperty -Path `$template -Name IsReadOnly -Value `$false"
Write-Host "        Remove-Item `$template -Force"
Write-Host "    }"
Write-Host "    Copy-Item `$source `$template"
Write-Host "    Set-ItemProperty -Path `$template -Name IsReadOnly -Value `$true"
