<#
.SYNOPSIS
    Prepares the claude-base Hyper-V VM for manual maintenance.

.DESCRIPTION
    WHAT THIS SCRIPT DOES
      * Requires an elevated PowerShell session.
      * Stops any running ephemeral VMs matching -EphemeralVmNamePattern so
        they release their differencing disks.
      * Stops the base VM cleanly (force power off only with -Force).
      * Clears the read-only attribute on the template and base VHDX files.
      * Starts the base VM.
      * Switches the base VM to maintenance networking by calling
        -NetworkScriptPath with -Mode maintenance, which removes the
        outbound deny-all ACL and restores general internet access.
      * Opens vmconnect against the base VM unless -NoConnect is passed.
      * Prints the teardown sequence needed to finish the cycle.

    WHAT THIS SCRIPT DOES NOT DO
      * It does not update anything inside the VM. Package, npm and any other
        baseline changes are performed manually over SSH or the console.
      * It does not re-lock networking afterwards.
      * It does not shut the base VM down afterwards.
      * It does not destroy ephemeral VMs. They are only stopped, because a
        maintenance session that does not rebuild the template leaves them
        valid. Destroying them is part of the printed teardown sequence.
      * It does not rebuild the read-only template disk. Until that rebuild
        runs, new ephemeral VMs continue to clone the previous image.

    The teardown half of the cycle is printed at the end of a successful run
    and must be executed by hand.

.NOTES
    Ephemeral VMs are differencing disks parented to the template VHDX.
    Replacing that file breaks the parent linkage and leaves those VMs
    unbootable, so they must be destroyed before the template is rebuilt.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseVmName = "claude-base",

    [string]$EphemeralVmNamePattern = "claude-ephemeral-*",

    [string]$BaseVhdPath = "C:\HyperV\claude-base\claude-base.vhdx",

    [string]$TemplateVhdPath = "C:\VMs\templates\claude-base-template.vhdx",

    [string]$NetworkScriptPath = "C:\VMs\Set-ClaudeVMNetworkMode.ps1",

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

$RemoveEphemeralScriptPath = Join-Path $PSScriptRoot "Remove-ClaudeEphemeral.ps1"

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
Write-Host ('    Stop-VM -Name "{0}"' -f $BaseVmName)
Write-Host ('    while ((Get-VM -Name "{0}").State -ne "Off") {{ Start-Sleep -Seconds 2 }}' -f $BaseVmName)
Write-Host ('    & "{0}" -Mode locked' -f $NetworkScriptPath)
Write-Host ""
Write-Host "Destroy every ephemeral VM before rebuilding the template. Their"
Write-Host "differencing disks are parented to the template file, so replacing it"
Write-Host "breaks the parent linkage and leaves those VMs unbootable:"
Write-Host ""
Write-Host ('    Get-VM | Where-Object Name -like "{0}"' -f $EphemeralVmNamePattern)
Write-Host ""
Write-Host ('    Get-VM | Where-Object Name -like "{0}" | ForEach-Object {{' -f $EphemeralVmNamePattern)
Write-Host ('        & "{0}" -Name $_.Name' -f $RemoveEphemeralScriptPath)
Write-Host '    }'
Write-Host ""
Write-Host "Then rebuild the read-only template disk:"
Write-Host ""
Write-Host ('    $template = "{0}"' -f $TemplateVhdPath)
Write-Host ('    $source   = "{0}"' -f $BaseVhdPath)
Write-Host '    if (Test-Path $template) {'
Write-Host '        Set-ItemProperty -Path $template -Name IsReadOnly -Value $false'
Write-Host '        Remove-Item $template -Force'
Write-Host '    }'
Write-Host '    Copy-Item $source $template'
Write-Host '    Set-ItemProperty -Path $template -Name IsReadOnly -Value $true'
