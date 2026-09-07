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
        outbound deny-all ACL and restores general internet access, then
        re-reads the ACLs and fails if that deny rule is still present.
      * With -AutoUpdateGuest, connects over SSH and, in one sudo session:
        upgrades apt packages, installs the pinned Claude Code version as a
        root-owned npm global, updates Codex for the sandbox user, and copies
        the contents of -SharedFolderPath into the sandbox home directory.
        sudo prompts once, interactively. No password is stored anywhere.
      * Opens vmconnect against the base VM unless -NoConnect is passed.
      * Prints the teardown sequence needed to finish the cycle.

    WHAT THIS SCRIPT DOES NOT DO
      * Without -AutoUpdateGuest it does not update anything inside the VM.
        Baseline changes are then performed manually over SSH or the console.
      * It does not run unattended. -AutoUpdateGuest still requires the sudo
        password to be typed once. For unattended runs, add a scoped NOPASSWD
        rule in /etc/sudoers.d/ for the specific commands involved.
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

    [string]$BaseVmIp = "172.30.101.50",

    [string]$SshUser = "user",

    [string]$SshKeyPath = "C:\VMs\ssh\claude_sandbox_ed25519",

    [string]$SandboxUser = "sandbox",

    [string]$ClaudeCodeVersion = "2.1.258",

    [string]$SharedFolderPath = "C:\VMs\SharedFolder",

    [int]$SshTimeoutSeconds = 180,

    [switch]$AutoUpdateGuest,

    [switch]$SkipAgentCheck,

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

function Wait-ForSsh {
    param(
        [Parameter(Mandatory)]
        [string]$IpAddress,

        [int]$TimeoutSeconds = 180
    )

    Write-Step "Waiting for SSH on ${IpAddress}:22 (timeout ${TimeoutSeconds}s)..."

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $reachable = Test-NetConnection `
            -ComputerName $IpAddress `
            -Port 22 `
            -InformationLevel Quiet `
            -WarningAction SilentlyContinue

        if ($reachable) {
            Write-Ok "SSH is accepting connections."
            return
        }

        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "SSH did not become available on $IpAddress within $TimeoutSeconds seconds."
}

function Test-SshAgentKey {
    if (-not (Get-Command ssh-add.exe -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-add.exe not found. Cannot check for a loaded agent key."
        return
    }

    & ssh-add.exe -l 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "SSH agent has a key loaded. No passphrase prompts expected."
        return
    }

    $message = @(
        "No key is loaded in the SSH agent."
        ""
        "$SshKeyPath is passphrase-protected. Without an agent key, each SSH and SCP"
        "call in this run prompts for the passphrase, and those prompts do not always"
        "render inside a script, which looks like a hang. Load the key first:"
        ""
        "    Set-Service ssh-agent -StartupType Manual"
        "    Start-Service ssh-agent"
        "    ssh-add `"$SshKeyPath`""
        "    ssh-add -l"
        ""
        "Re-run with -SkipAgentCheck to proceed anyway and answer the prompts by hand."
    ) -join [Environment]::NewLine

    if ($SkipAgentCheck) {
        Write-Warn $message
        return
    }

    throw $message
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)]
        [string[]]$SshArgument,

        [switch]$Interactive
    )

    $baseArgs = @(
        "-i", $SshKeyPath,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10"
    )

    if ($Interactive) {
        $baseArgs += "-t"
    }

    $allArgs = $baseArgs + @("$SshUser@$BaseVmIp") + $SshArgument

    & ssh.exe @allArgs

    if ($LASTEXITCODE -ne 0) {
        throw "ssh failed with exit code $LASTEXITCODE"
    }
}

function Copy-ToGuest {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $scpArgs = @(
        "-r",
        "-i", $SshKeyPath,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10"
    ) + $Path + @("${SshUser}@${BaseVmIp}:${Destination}")

    & scp.exe @scpArgs

    if ($LASTEXITCODE -ne 0) {
        throw "scp failed with exit code $LASTEXITCODE"
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Get-AclRemoteAddress {
    param(
        [Parameter(Mandatory)]
        $Acl
    )

    $property = $Acl.PSObject.Properties["RemoteAddress"]

    if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return ([string]$property.Value).Trim()
    }

    throw "Could not read the remote address of a VM network adapter ACL. Maintenance networking cannot be verified."
}

function Get-OutboundDenyAllAcl {
    param(
        [Parameter(Mandatory)]
        [string]$VmName
    )

    $denyAllAddresses = @("0.0.0.0/0", "0.0.0.0")

    return @(
        Get-VMNetworkAdapterAcl -VMName $VmName |
            Where-Object {
                $_.Direction -eq "Outbound" -and
                $_.Action -eq "Deny" -and
                $denyAllAddresses -contains (Get-AclRemoteAddress -Acl $_)
            }
    )
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

if ($AutoUpdateGuest) {
    # Checked before anything is stopped, so a missing agent key does not cost
    # a needless shutdown and restart of a running base VM.
    Test-SshAgentKey
}

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

$maintenanceNetworkingApplied = $false

if (Test-Path $NetworkScriptPath) {
    if ($PSCmdlet.ShouldProcess($NetworkScriptPath, "Enable maintenance networking")) {
        & $NetworkScriptPath -Mode maintenance
        $maintenanceNetworkingApplied = $true
    }

    Write-Ok "Maintenance networking enabled."
}
else {
    Write-Warn "Network control script not found. Skipping: $NetworkScriptPath"
}

if ($maintenanceNetworkingApplied) {
    Write-Step "Verifying the outbound deny-all ACL is gone..."

    $denyAllAcls = @(Get-OutboundDenyAllAcl -VmName $BaseVmName)

    if ($denyAllAcls.Count -gt 0) {
        Get-VMNetworkAdapterAcl -VMName $BaseVmName | Format-Table -AutoSize | Out-String | Write-Host

        throw "Maintenance networking did not take effect: an outbound 0.0.0.0/0 Deny ACL is still present on $BaseVmName. The base VM has no general internet access. Fix the ACLs before continuing."
    }

    Write-Ok "No outbound deny-all ACL remains on $BaseVmName."
}

if ($AutoUpdateGuest) {
    Write-Step "Updating the guest over SSH..."

    Wait-ForSsh -IpAddress $BaseVmIp -TimeoutSeconds $SshTimeoutSeconds

    $staging = "/tmp/claude-base-staging"

    Write-Step "Preparing staging directory in the guest..."
    Invoke-Ssh -SshArgument @("rm -rf '$staging' && mkdir -p '$staging'")

    $sharedItems = @()

    if (Test-Path $SharedFolderPath) {
        $sharedItems = @(
            Get-ChildItem -LiteralPath $SharedFolderPath -Force |
                ForEach-Object { $_.FullName }
        )
    }
    else {
        Write-Warn "Shared folder not found, skipping copy: $SharedFolderPath"
    }

    if ($sharedItems.Count -gt 0) {
        Write-Step "Copying $($sharedItems.Count) item(s) from $SharedFolderPath to the guest..."
        Copy-ToGuest -Path $sharedItems -Destination "$staging/"
        Write-Ok "Shared folder staged in the guest."
    }
    else {
        Write-Ok "Shared folder is empty. Nothing to copy."
    }

    $remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

# Remove this script on exit. bash already holds the file open, so the
# unlink is safe and avoids a second SSH call just to clean up.
trap 'rm -f /tmp/claude-base-maint.sh' EXIT

SANDBOX_USER="__SANDBOX_USER__"
SANDBOX_HOME="/home/__SANDBOX_USER__"
STAGING="/tmp/claude-base-staging"
CLAUDE_VERSION="__CLAUDE_VERSION__"

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt packages..."
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold upgrade
apt-get -y autoremove
apt-get clean

echo "[*] Installing Claude Code ${CLAUDE_VERSION} (root-owned npm global)..."
npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}"

echo "[*] Installing Claude Code ${CLAUDE_VERSION} for ${SANDBOX_USER}..."
# The sandbox user has its own npm prefix, and that bin directory precedes
# /usr/local/bin on PATH. Without this step the root-owned global is updated
# but the account that actually runs Claude keeps its shadowing copy.
sudo -u "${SANDBOX_USER}" -H bash -lc "npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}"

echo "[*] Updating Codex for ${SANDBOX_USER}..."
sudo -u "${SANDBOX_USER}" -H bash -lc 'npm install -g @openai/codex'

if [ -d "${STAGING}" ] && [ -n "$(ls -A "${STAGING}" 2>/dev/null)" ]; then
    echo "[*] Copying shared folder contents into ${SANDBOX_HOME}..."

    for item in "${STAGING}"/* "${STAGING}"/.[!.]*; do
        [ -e "${item}" ] || continue
        target="${SANDBOX_HOME}/$(basename "${item}")"
        if [ -e "${target}" ]; then
            echo "    OVERWRITING: ${target}"
        else
            echo "    adding:      ${target}"
        fi
    done

    cp -a "${STAGING}"/. "${SANDBOX_HOME}"/
    chown -R "${SANDBOX_USER}:${SANDBOX_USER}" "${SANDBOX_HOME}"
    rm -rf "${STAGING}"

    echo "[+] Shared folder contents copied."
else
    echo "[*] No shared folder content to copy."
fi

echo "[*] Installed versions:"
printf '    root claude:    '
claude --version || echo "not available"
printf '    %s claude: ' "${SANDBOX_USER}"
sudo -u "${SANDBOX_USER}" -H bash -lc 'claude --version' || echo "not available"
printf '    %s codex:  ' "${SANDBOX_USER}"
sudo -u "${SANDBOX_USER}" -H bash -lc 'codex --version' || echo "not available"

echo "[+] Guest update complete."
'@

    $remoteScript = $remoteScript.
        Replace("__SANDBOX_USER__", $SandboxUser).
        Replace("__CLAUDE_VERSION__", $ClaudeCodeVersion).
        Replace("`r`n", "`n")

    $localScript = Join-Path $env:TEMP "claude-base-maint.sh"

    [System.IO.File]::WriteAllText(
        $localScript,
        $remoteScript,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Step "Uploading guest maintenance script..."
    Copy-ToGuest -Path @($localScript) -Destination "/tmp/claude-base-maint.sh"

    Write-Host ""
    Write-Host "sudo will prompt for the password of '$SshUser' once, below."
    Write-Host ""

    if ($PSCmdlet.ShouldProcess($BaseVmName, "Run guest maintenance over SSH")) {
        Invoke-Ssh -Interactive -SshArgument @("sudo bash /tmp/claude-base-maint.sh")
    }

    Remove-Item $localScript -Force -ErrorAction SilentlyContinue

    Write-Ok "Guest update finished."
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
# Every command below is printed flush left and on a single line so it can be
# pasted straight into the console. Leading indentation and multi-line blocks
# do not survive a paste into PowerShell, so do not "tidy" this output.
Write-Host "After updating the base VM, shut it down cleanly, re-lock networking, and rebuild the template."
Write-Host "Each line below can be pasted as-is."
Write-Host ""
Write-Host "--- 1. Shut down and re-lock ---"
Write-Host ""
Write-Host ('Stop-VM -Name "{0}"' -f $BaseVmName)
Write-Host ('while ((Get-VM -Name "{0}").State -ne "Off") {{ Start-Sleep -Seconds 2 }}' -f $BaseVmName)
Write-Host ('& "{0}" -Mode locked' -f $NetworkScriptPath)
Write-Host ""
Write-Host "Add -Atlassian to that last line if this VM needs Jira access. Locked mode"
Write-Host "removes any allow rule it does not own, so re-locking without the switch"
Write-Host "revokes Atlassian access."
Write-Host ""
Write-Host "--- 2. Destroy ephemeral VMs ---"
Write-Host ""
Write-Host ""
Write-Host ('Get-VM | Where-Object Name -like "{0}"' -f $EphemeralVmNamePattern)
Write-Host ('Get-VM | Where-Object Name -like "{0}" | ForEach-Object {{ & "{1}" -Name $_.Name }}' -f $EphemeralVmNamePattern, $RemoveEphemeralScriptPath)
Write-Host ""
Write-Host "--- 3. Rebuild the read-only template disk ---"
Write-Host ""
Write-Host ('$template = "{0}"' -f $TemplateVhdPath)
Write-Host ('$source = "{0}"' -f $BaseVhdPath)
Write-Host 'if (Test-Path $template) { Set-ItemProperty -Path $template -Name IsReadOnly -Value $false; Remove-Item $template -Force }'
Write-Host 'Copy-Item $source $template'
Write-Host 'Set-ItemProperty -Path $template -Name IsReadOnly -Value $true'
