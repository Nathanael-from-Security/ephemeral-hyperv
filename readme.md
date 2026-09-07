# Hyper-V AI Sandbox Setup

This document describes the process for setting up a hardened Hyper-V-based Linux VM for running an AI coding sandbox.

The target design is:

* Windows host running Hyper-V
* Internal Hyper-V NAT network
* Ubuntu Linux VM
* Non-root sandbox user
* SSH access from the Windows host
* VM outbound access restricted with Hyper-V VM network adapter ACLs
* Claude/Anthropic access allowed by IP range
* Maintenance mode for package installs and updates
* Optional ephemeral VMs created from a read-only base template and destroyed after a task

The current working design does **not** use Squid or a host-side proxy.

## Assumptions

This guide assumes:

* The Windows host supports Hyper-V.
* The VM network uses the subnet `172.30.101.0/24`.
* The Windows host-side NAT interface uses `172.30.101.1`.
* The Linux VM uses `172.30.101.50`.
* The Hyper-V switch is named `fresh-claude-switch`.
* The Windows NAT is named `fresh-claude-nat`.
* The base VM name is `claude-base`.
* The base VM network adapter is named `fresh-claude-adapter`.
* The template disk is stored at `C:\VMs\templates\claude-base-template.vhdx`.
* Ephemeral VM files are stored under `C:\VMs\ephemeral`.

Adjust names, paths, and IP addresses as needed.

---

## 1. Confirm Windows Edition and Hyper-V Support

Hyper-V requires a Windows edition that includes Hyper-V support, such as:

* Windows Pro
* Windows Enterprise
* Windows Education

Confirm the following before continuing:

1. Windows edition supports Hyper-V.
2. CPU virtualization is enabled in BIOS/UEFI.
3. Hyper-V is installed and enabled.

Useful checks:

```powershell
systeminfo
```

Look for the Hyper-V requirements section.

You can also check whether Hyper-V PowerShell commands are available:

```powershell
Get-Command New-VM
Get-Command New-VMSwitch
```

If Hyper-V is not enabled, enable it from an elevated PowerShell prompt:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Reboot if prompted.

---

## 2. Create the Hyper-V Internal Switch

Create an internal Hyper-V switch for the sandbox network:

```powershell
New-VMSwitch -Name "fresh-claude-switch" -SwitchType Internal
```

Verify the switch:

```powershell
Get-VMSwitch -Name "fresh-claude-switch"
```

You should now have a virtual adapter on the Windows host named:

```text
vEthernet (fresh-claude-switch)
```

---

## 3. Assign the Host-Side NAT IP Address

Assign an IP address to the host-side Hyper-V virtual adapter:

```powershell
New-NetIPAddress `
  -InterfaceAlias "vEthernet (fresh-claude-switch)" `
  -IPAddress 172.30.101.1 `
  -PrefixLength 24
```

Verify:

```powershell
Get-NetIPAddress -InterfaceAlias "vEthernet (fresh-claude-switch)"
```

Expected result:

```text
IPAddress      : 172.30.101.1
PrefixLength   : 24
InterfaceAlias : vEthernet (fresh-claude-switch)
```

---

## 4. Create the Windows NAT

Create the NAT network:

```powershell
New-NetNat `
  -Name "fresh-claude-nat" `
  -InternalIPInterfaceAddressPrefix "172.30.101.0/24"
```

Verify:

```powershell
Get-NetNat -Name "fresh-claude-nat"
```

Expected result:

```text
Name                             : fresh-claude-nat
InternalIPInterfaceAddressPrefix : 172.30.101.0/24
Active                           : True
```

---

## 5. Download Ubuntu Server ISO

Download an Ubuntu Server ISO, for example:

```text
ubuntu-24.04-live-server-amd64.iso
```

Place the ISO somewhere accessible to Hyper-V, for example:

```text
C:\Users\X\Downloads\ubuntu-24.04-live-server-amd64.iso
```

---

## 6. Create the Base Linux VM

Create a new Generation 2 VM:

```powershell
New-VM `
  -Name "claude-base" `
  -Generation 2 `
  -MemoryStartupBytes 6GB `
  -NewVHDPath "C:\HyperV\claude-base\claude-base.vhdx" `
  -NewVHDSizeBytes 80GB `
  -SwitchName "fresh-claude-switch"
```

Configure CPU:

```powershell
Set-VMProcessor -VMName "claude-base" -Count 4
```

For Ubuntu on Generation 2 Hyper-V, use the Microsoft UEFI Certificate Authority Secure Boot template:

```powershell
Set-VMFirmware `
  -VMName "claude-base" `
  -EnableSecureBoot On `
  -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
```

Attach the Ubuntu ISO:

```powershell
Add-VMDvdDrive `
  -VMName "claude-base" `
  -Path "C:\Users\X\Downloads\ubuntu-24.04-live-server-amd64.iso"
```

Set the DVD drive as the first boot device:

```powershell
$dvd = Get-VMDvdDrive -VMName "claude-base"

Set-VMFirmware `
  -VMName "claude-base" `
  -FirstBootDevice $dvd
```

Start the VM:

```powershell
Start-VM -Name "claude-base"
```

Connect to the VM console:

```powershell
vmconnect.exe localhost "claude-base"
```

---

## 7. Install Ubuntu

Go through the Ubuntu Server installer.

Recommended baseline choices:

* Install OpenSSH server.
* Use a normal non-root admin user for initial setup.
* Use the Hyper-V virtual disk as the install target.
* Apply security updates during install if network connectivity is available.

After installation, reboot the VM and remove or detach the ISO if needed.

Check VM status from the host:

```powershell
Get-VM -Name "claude-base"
```

---

## 8. Test IPv4 Networking in Ubuntu

After Ubuntu boots, log in through the VM console.

Check the VM’s network interfaces:

```bash
ip addr
```

Check for an IPv4 address:

```bash
ip -4 addr
```

Check routing:

```bash
ip -4 route
```

Check connectivity to the Hyper-V host-side NAT IP:

```bash
ping -c 4 172.30.101.1
```

If ping fails, that may be Windows Firewall blocking ICMP to the host. Use SSH and outbound tests as the primary validation.

Temporarily test outbound connectivity before network hardening:

```bash
ping -c 4 1.1.1.1
```

DNS test:

```bash
getent hosts ubuntu.com
```

---

## 9. Configure Netplan if DHCP Does Not Work

If the VM does not receive an IPv4 address through DHCP, inspect Netplan:

```bash
ls -la /etc/netplan
cat /etc/netplan/*.yaml
```

Identify the network interface name:

```bash
ip link
```

Common names include:

```text
eth0
ens160
enp0s3
```

Create or edit a Netplan file:

```bash
sudo nano /etc/netplan/01-ai-sandbox.yaml
```

For DHCP:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
```

Replace `eth0` with the actual interface name.

Apply Netplan:

```bash
sudo netplan generate
sudo netplan apply
```

Retest:

```bash
ip -4 addr
ip -4 route
```

---

## 10. Configure Static IPv4

For a stable sandbox VM, configure a fixed IP.

Edit the Netplan file:

```bash
sudo nano /etc/netplan/01-ai-sandbox.yaml
```

Example static configuration:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - 172.30.101.50/24
      routes:
        - to: default
          via: 172.30.101.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
```

Apply:

```bash
sudo netplan generate
sudo netplan apply
```

Verify:

```bash
ip -4 addr
ip -4 route
```

The route output should include something like:

```text
default via 172.30.101.1 dev eth0
```

---

## 11. Create a Non-Root Sandbox User

Create a dedicated non-root user for sandbox work:

```bash
sudo adduser sandbox
```

Optionally allow the user to use `sudo`:

```bash
sudo usermod -aG sudo sandbox
```

For a stricter sandbox, avoid adding this user to `sudo` unless needed.

Create the SSH directory:

```bash
sudo mkdir -p /home/sandbox/.ssh
sudo chmod 700 /home/sandbox/.ssh
sudo chown sandbox:sandbox /home/sandbox/.ssh
```

On the Windows host, generate an SSH key if needed:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\ai-sandbox-ed25519"
```

Copy the public key content:

```powershell
Get-Content "$env:USERPROFILE\.ssh\ai-sandbox-ed25519.pub"
```

On the Ubuntu VM, add the public key:

```bash
sudo nano /home/sandbox/.ssh/authorized_keys
```

Paste the public key, then set permissions:

```bash
sudo chmod 600 /home/sandbox/.ssh/authorized_keys
sudo chown sandbox:sandbox /home/sandbox/.ssh/authorized_keys
```

Test SSH from the Windows host:

```powershell
ssh -i "$env:USERPROFILE\.ssh\ai-sandbox-ed25519" sandbox@172.30.101.50
```

---

## 12. Harden SSH Configuration

Edit the SSH server configuration:

```bash
sudo nano /etc/ssh/sshd_config
```

Recommended settings:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers sandbox
```

Validate the SSH config:

```bash
sudo sshd -t
```

Restart SSH:

```bash
sudo systemctl restart ssh
```

Test SSH again from the Windows host before closing the console session:

```powershell
ssh -i "$env:USERPROFILE\.ssh\ai-sandbox-ed25519" sandbox@172.30.101.50
```

---

## 13. Install the Agent CLIs

Install prerequisites while the VM still has temporary unrestricted outbound access:

```bash
sudo apt update
sudo apt install -y curl ca-certificates gnupg git nodejs npm
```

The two CLIs are installed differently, and the maintenance workflow in section 19 depends on that difference:

* **Claude Code** is a root-owned npm global, available to every account in the VM.
* **Codex** is installed under the `sandbox` user's own npm prefix, so it exists only for that account.

### Claude Code

Install a pinned version so the image is reproducible:

```bash
sudo npm install -g @anthropic-ai/claude-code@2.1.258
claude --version
```

### Codex

`npm install -g` as a non-root user writes to a user-level prefix, so give `sandbox` one and put it on the path before installing:

```bash
sudo -u sandbox -H bash -lc 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global'
sudo -u sandbox -H bash -lc 'grep -q ".npm-global/bin" ~/.profile || echo "export PATH=\"\$HOME/.npm-global/bin:\$PATH\"" >> ~/.profile'
```

Install and verify:

```bash
sudo -u sandbox -H bash -lc 'npm install -g @openai/codex'
sudo -u sandbox -H bash -lc 'codex --version'
```

If `codex --version` reports command not found, the prefix is not on the path for that login shell. Re-check `~/.profile` and confirm `bash -lc` is being used, since a non-login shell will not read it.

### Authentication

Run initial authentication or setup as the sandbox user:

```bash
su - sandbox
claude
codex
```

Codex sign-in requires the OpenAI endpoints to be reachable. In locked mode they are not, unless they have been added to the allowlist and pinned in `/etc/hosts`. See section 17.

### Auto-update behaviour

Locked clones cannot reach the npm registry, so a CLI's own auto-updater can only produce failing background calls. Pinning versions here and updating through the section 19 maintenance cycle keeps the image content deliberate. Set `DISABLE_AUTOUPDATER=1` in the environment if you want to suppress those attempts entirely.

---

## 14. Remove Old Proxy Configuration

This setup does not use a proxy. If the VM contains old proxy configuration, remove it.

Check for proxy variables:

```bash
env | grep -i proxy
```

Search common locations:

```bash
grep -RniE 'http_proxy|https_proxy|all_proxy|no_proxy|172\.30\.100\.1|3128' \
  ~/.bashrc ~/.profile ~/.bash_profile /etc/environment /etc/profile /etc/profile.d /etc/apt/apt.conf /etc/apt/apt.conf.d 2>/dev/null
```

If `/etc/profile.d/sandbox-proxy.sh` exists, disable it:

```bash
sudo mv /etc/profile.d/sandbox-proxy.sh /etc/profile.d/sandbox-proxy.sh.disabled
```

Clear the current shell:

```bash
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy ALL_PROXY all_proxy
```

Start a fresh login shell:

```bash
exec bash -l
```

Verify:

```bash
env | grep -i proxy
```

Expected result: no output.

---

## 15. Pin Claude Hostnames in `/etc/hosts`

Locked mode blocks normal outbound DNS. Pin the Claude hostnames used by Claude Code.

On the Windows host, resolve the current IP:

```powershell
Resolve-DnsName api.anthropic.com -Type A
Resolve-DnsName platform.claude.com -Type A
Resolve-DnsName claude.ai -Type A
```

In the VM, edit `/etc/hosts`:

```bash
sudo nano /etc/hosts
```

Add the resolved IP for all required Claude hostnames:

```text
160.79.104.10 api.anthropic.com
160.79.104.10 platform.claude.com
160.79.104.10 claude.ai
```

Use the IP returned by DNS. The example above uses `160.79.104.10`.

Verify:

```bash
getent hosts api.anthropic.com
getent hosts platform.claude.com
getent hosts claude.ai
```

Test direct connectivity without a proxy:

```bash
curl -v --noproxy '*' --connect-timeout 10 https://api.anthropic.com/
curl -v --noproxy '*' --connect-timeout 10 https://platform.claude.com/
curl -v --noproxy '*' --connect-timeout 10 https://claude.ai/
```

A `401`, `403`, or `404` response is acceptable. The important result is that TCP/TLS connectivity succeeds.

---

## 16. Add a Login Connectivity Warning

Create a system-wide login check:

```bash
sudo nano /etc/profile.d/claude-api-check.sh
```

Add:

```bash
#!/usr/bin/env bash

CLAUDE_HOST="api.anthropic.com"
CLAUDE_RANGE_REGEX='^160\.79\.(10[4-9]|11[0-1])\.'

resolved_ips="$(getent ahostsv4 "$CLAUDE_HOST" 2>/dev/null | awk '{print $1}' | sort -u)"

if [ -z "$resolved_ips" ]; then
  echo
  echo "AI SANDBOX WARNING: Claude API DNS is not resolving."
  echo "Run this on the Windows host:"
  echo "  Resolve-DnsName api.anthropic.com -Type A"
  echo
  echo "Then update inside the VM:"
  echo "  sudo nano /etc/hosts"
  echo
  echo "Expected /etc/hosts format:"
  echo "  <resolved-ip> api.anthropic.com"
  echo
  return 0 2>/dev/null || exit 0
fi

valid_ip="$(echo "$resolved_ips" | grep -E "$CLAUDE_RANGE_REGEX" | head -n 1)"

if [ -z "$valid_ip" ]; then
  echo
  echo "AI SANDBOX WARNING: api.anthropic.com resolves, but not to the allowed Claude API range."
  echo "Resolved IPs:"
  echo "$resolved_ips" | sed 's/^/  /'
  echo
  echo "Expected range:"
  echo "  160.79.104.0 - 160.79.111.255"
  echo
  echo "Update /etc/hosts or check the Hyper-V ACL allowlist."
  return 0 2>/dev/null || exit 0
fi

if command -v curl >/dev/null 2>&1; then
  if ! curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 "https://$CLAUDE_HOST/" >/dev/null 2>&1; then
    echo
    echo "AI SANDBOX WARNING: $CLAUDE_HOST resolves to $valid_ip, but HTTPS connectivity failed."
    echo "Check Hyper-V ACLs and proxy environment variables."
    echo "Useful checks:"
    echo "  env | grep -i proxy"
    echo "  curl -v --noproxy '*' --connect-timeout 10 https://api.anthropic.com/"
  fi
fi
```

Set permissions:

```bash
sudo chmod +x /etc/profile.d/claude-api-check.sh
```

Reload the login shell:

```bash
exec bash -l
```

This applies system-wide for users whose shell reads `/etc/profile`, including normal SSH login sessions.

---

## 17. Harden Hyper-V Network ACLs

Once the VM has the intended static IP, harden the Hyper-V network ACLs from an elevated PowerShell prompt on the Windows host.

This policy allows outbound traffic only to:

* The Hyper-V host NAT IP: `172.30.101.1`
* Claude/Anthropic IP range: `160.79.104.0/21`

All other VM outbound traffic is denied.

```powershell
$VM        = "claude-base"
$Adapter   = "fresh-claude-adapter"
$HostIP    = "172.30.101.1"
$ClaudeAPI = "160.79.104.0/21"

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
```

Verify ACLs:

```powershell
Get-VMNetworkAdapterAcl `
  -VMName "claude-base" `
  -VMNetworkAdapterName "fresh-claude-adapter"
```

Expected result:

```text
Outbound Remote 172.30.101.1       Allow
Outbound Remote 160.79.104.0/21    Allow
Outbound Remote 0.0.0.0/0          Deny
```

This does not add inbound ACLs. SSH from the Windows host can continue to work, while the VM can only initiate outbound traffic to the host and the Claude range.

---

### Add Whitelisted AI Provider IP

When adding or changing whitelisted provider IPs, update these places together so locked-mode networking remains consistent:

1. **Lock script allowlist**: update the `$Allowlist` array near the top of `C:\VMs\Set-ClaudeVMNetworkMode.ps1`. This is the only definition of the locked-mode allowlist. `New-ClaudeEphemeral.ps1` calls that script rather than keeping its own copy, so ephemeral VMs pick the change up automatically.
2. **Linux `/etc/hosts` file**: update pinned hostnames inside the base VM when locked mode blocks normal outbound DNS.
3. **Display Provider Warnings**: update `/etc/profile.d` for warnings that should appear for all interactive login shell users.

Be careful pinning single addresses for CDN-fronted services. Hosts behind Cloudflare, Fastly, or similar providers resolve to rotating anycast addresses, so a `/32` that works today can stop being the answer returned by DNS later. Prefer the provider's published range, or accept that such entries need periodic re-checking.

For Codex/OpenAI API-only access, only pin and allow the required API/auth hostnames, for example:

```text
api.openai.com
auth.openai.com
```

Do not add `chatgpt.com` or `platform.openai.com` unless the VM is expected to use browser-based ChatGPT sign-in, installer downloads, or dashboard access.

After updating IPs, validate from inside the VM:

```bash
getent hosts api.openai.com
getent hosts auth.openai.com
curl -4 -Iv https://api.openai.com
curl -4 -Iv https://auth.openai.com/api/accounts/deviceauth/usercode
```

A `400`, `401`, `403`, or `405` response means TCP/TLS connectivity is working. A timeout, DNS failure, or TLS failure means the allowlist, ACL, or `/etc/hosts` entries need correction.


## 18. Maintenance Mode Toggle

Locked and maintenance modes are toggled by `C:\VMs\Set-ClaudeVMNetworkMode.ps1`. It is the single source of truth for the locked-mode allowlist and is used both by this workflow and by `New-ClaudeEphemeral.ps1` when it applies ACLs to a new clone.

Parameters:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Mode` | required | `locked`, `maintenance`, or `status` |
| `-VMName` | `claude-base` | VM whose adapter ACLs are changed |
| `-AdapterName` | auto-detected | resolved from the VM when not supplied |
| `-SwitchName` | `fresh-claude-switch` | used to resolve the host-side IP |

Behaviour:

* `maintenance` removes only the outbound `0.0.0.0/0` deny rule. The allow rules stay in place and the VM regains general outbound internet access.
* `locked` re-applies every entry in the `$Allowlist` array, then re-applies the outbound `0.0.0.0/0` deny.
* `status` prints the current ACLs and changes nothing.

The host IP is resolved at runtime from `vEthernet (fresh-claude-switch)` rather than hardcoded. Provider entries are hardcoded in the `$Allowlist` array near the top of the script.

Use it from elevated PowerShell:

```powershell
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode status -VMName claude-base
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode maintenance -VMName claude-base
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode locked -VMName claude-base
```

If PowerShell blocks execution:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode status
```

`Set-ExecutionPolicy -Scope Process Bypass` must be run in the calling session before the script is invoked. It cannot be placed inside the script, because the execution policy is evaluated before the file is parsed.

---

## 19. Maintenance Workflow for the Base VM

Run updates on the base VM, then rebuild the read-only template disk so new clones inherit the changes.

Do not update an ephemeral VM if you want the update to persist. Ephemeral VM changes are discarded when the VM is destroyed.

`C:\VMs\Update-ClaudeBase.ps1` automates the preparation half. It stops running ephemeral VMs, stops the base VM, clears the read-only attribute on the base and template disks, starts the base VM, switches it to maintenance networking, and opens `vmconnect`. With `-AutoUpdateGuest` it also performs the in-VM update described below. It does not re-lock networking, does not destroy ephemeral VMs, and does not rebuild the template. Those steps are manual and are listed below and in the script's own closing output.

Full cycle:

1. Prepare the base VM with `Update-ClaudeBase.ps1`.
2. Confirm maintenance networking is active.
3. Run updates inside `claude-base`, either with `-AutoUpdateGuest` or by hand.
4. Re-lock `claude-base`.
5. Shut down `claude-base` and wait for `Off`.
6. Destroy every ephemeral VM.
7. Rebuild `C:\VMs\templates\claude-base-template.vhdx` and mark it read-only.

Host, prepare the base VM:

```powershell
Set-ExecutionPolicy -Scope Process Bypass

C:\VMs\Update-ClaudeBase.ps1
C:\VMs\Update-ClaudeBase.ps1 -Force
C:\VMs\Update-ClaudeBase.ps1 -NoConnect
```

Host, confirm maintenance networking before connecting. There must be no `0.0.0.0/0 Deny` row. If there is, apply the mode manually:

```powershell
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode status -VMName claude-base
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode maintenance -VMName claude-base
```

### Automated guest update

`-AutoUpdateGuest` performs the in-VM work over SSH instead of by hand:

```powershell
C:\VMs\Update-ClaudeBase.ps1 -Force -NoConnect -AutoUpdateGuest
```

It waits for port 22 to accept connections, stages the shared folder, then runs a single `sudo` session in the guest that:

* runs `apt-get update`, `upgrade`, `autoremove` and `clean` with `DEBIAN_FRONTEND=noninteractive` and `--force-confold`;
* installs the pinned Claude Code version as a root-owned npm global;
* runs `npm install -g @openai/codex` as the sandbox user, via `sudo -u`;
* copies the contents of `C:\VMs\SharedFolder\` into `/home/sandbox` and applies `chown -R sandbox:sandbox`;
* prints the resulting `claude` and `codex` versions.

Relevant parameters:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-AutoUpdateGuest` | off | Opt in to the in-VM update. Nothing below applies without it. |
| `-BaseVmIp` | `172.30.101.50` | Guest address used for SSH and SCP |
| `-SshUser` | `user` | Administrative account used to log in and run `sudo` |
| `-SshKeyPath` | `C:\VMs\ssh\claude_sandbox_ed25519` | Private key for both accounts |
| `-SandboxUser` | `sandbox` | Workload account that owns `/home/sandbox` and runs codex |
| `-ClaudeCodeVersion` | `2.1.258` | Pinned npm version, for a reproducible image |
| `-SharedFolderPath` | `C:\VMs\SharedFolder` | Host folder copied into the sandbox home directory |
| `-SshTimeoutSeconds` | `180` | How long to wait for SSH after the VM starts |

Notes and limitations:

* `sudo` prompts once for the password of `-SshUser`, interactively, because the whole guest update runs in one `ssh -t` session. No password is stored in the script, in a file, or in the environment. For genuinely unattended runs, add a scoped `NOPASSWD` rule in `/etc/sudoers.d/` for the specific commands rather than storing a secret.
* `claude_sandbox_ed25519` is passphrase-protected. Load it into the Windows SSH agent once per session, or each of the four SSH and SCP calls in the run will prompt separately:

```powershell
Start-Service ssh-agent
ssh-add "C:\VMs\ssh\claude_sandbox_ed25519"
ssh-add -l
```

* Do not add `-o BatchMode=yes` to any command using this key. BatchMode forbids interactive prompts, so the passphrase cannot be supplied and ssh fails with `Permission denied (publickey,password)` — which reads like a wrong account or a missing key rather than a suppressed prompt.
* The shared folder copy overwrites same-named files in `/home/sandbox`, including dotfiles. Each path is printed as `OVERWRITING:` or `adding:` before the copy runs.
* Maintenance networking must be active first. If the network toggle script cannot be found, `Update-ClaudeBase.ps1` warns rather than throwing, and the guest update will then fail at the first `apt-get` fetch.
* `-WhatIf` covers the `sudo` session only. Staging directory creation and the SCP uploads still execute.

### Manual guest update

Equivalent steps if you are not using `-AutoUpdateGuest`. Inside `claude-base`:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
sudo apt clean

# Claude Code is a root-owned npm global install (section 13).
# Pin the version so the image is reproducible.
sudo npm install -g @anthropic-ai/claude-code@2.1.258
claude --version

# Codex is installed for the sandbox user only.
sudo -u sandbox -H bash -lc 'npm install -g @openai/codex'
sudo -u sandbox -H bash -lc 'codex --version'
```

Host, re-lock and shut down:

```powershell
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode locked -VMName claude-base
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode status -VMName claude-base

Stop-VM -Name "claude-base"

while ((Get-VM -Name "claude-base").State -ne "Off") {
    Start-Sleep -Seconds 2
}
```

Host, destroy ephemeral VMs before rebuilding the template. Their differencing disks are parented to the template file, so replacing it breaks the parent linkage and leaves those VMs unbootable. `Update-ClaudeBase.ps1` only stops them, it does not remove them:

```powershell
Get-VM | Where-Object Name -like "claude-ephemeral-*"

Get-VM | Where-Object Name -like "claude-ephemeral-*" | ForEach-Object {
    C:\VMs\Remove-ClaudeEphemeral.ps1 -Name $_.Name
}
```

Host, rebuild the template disk. Skipping this step leaves every new clone on the previous image:

```powershell
$template = "C:\VMs\templates\claude-base-template.vhdx"
$source   = "C:\HyperV\claude-base\claude-base.vhdx"

if (Test-Path $template) {
    Set-ItemProperty -Path $template -Name IsReadOnly -Value $false
    Remove-Item $template -Force
}

Copy-Item $source $template

Set-ItemProperty -Path $template -Name IsReadOnly -Value $true
```

Host, final sanity checks:

```powershell
Get-Item $template, $source | Select-Object FullName, IsReadOnly
Get-VM -Name "claude-base"
Get-VM | Where-Object Name -like "claude-ephemeral-*"
C:\VMs\Set-ClaudeVMNetworkMode.ps1 -Mode status -VMName claude-base
```

---

## 20. Create the Read-Only Template Disk

After `claude-base` is configured and shut down, create a template disk:

```powershell
New-Item -ItemType Directory -Force -Path "C:\VMs\templates" | Out-Null

Copy-Item `
  "C:\HyperV\claude-base\claude-base.vhdx" `
  "C:\VMs\templates\claude-base-template.vhdx"

Set-ItemProperty `
  -Path "C:\VMs\templates\claude-base-template.vhdx" `
  -Name IsReadOnly `
  -Value $true
```

Verify the base VM is using a normal `.vhdx`, not a checkpoint `.avhdx`:

```powershell
Get-VMHardDiskDrive -VMName "claude-base"
```

If the path ends in `.avhdx`, remove or merge checkpoints before creating the template.

Check snapshots:

```powershell
Get-VMSnapshot -VMName "claude-base"
```

Remove checkpoints if you want the current state to become the new base:

```powershell
Get-VMSnapshot -VMName "claude-base" | Remove-VMSnapshot
```

Then shut down and re-check the disk path:

```powershell
Stop-VM -Name "claude-base"
Get-VMHardDiskDrive -VMName "claude-base"
```

---

## 21. Create Ephemeral VMs

Ephemeral VMs use differencing disks based on the read-only template.

The model is:

```text
C:\VMs\templates\claude-base-template.vhdx
  -> C:\VMs\ephemeral\disks\<ephemeral-name>.vhdx
  -> disposable Hyper-V VM
```

This lets you run a single task in a clean copy and destroy all changes afterward.

Create the script:

```powershell
notepad C:\VMs\New-ClaudeEphemeral.ps1
```

Paste:

```powershell
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

Set-VMFirmware `
    -VMName $Name `
    -EnableSecureBoot On `
    -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

$BootDisk = Get-VMHardDiskDrive -VMName $Name

Set-VMFirmware `
    -VMName $Name `
    -FirstBootDevice $BootDisk

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

Start-VM -Name $Name

Write-Host ""
Write-Host "Started ephemeral VM: $Name"
Write-Host ""
Write-Host "Network ACLs:"
Get-VMNetworkAdapterAcl -VMName $Name -VMNetworkAdapterName $Adapter
Write-Host ""
Write-Host "Destroy with:"
Write-Host "  C:\VMs\Remove-ClaudeEphemeral.ps1 -Name $Name"
```

Create a locked ephemeral VM:

```powershell
C:\VMs\New-ClaudeEphemeral.ps1
```

Create one with a specific name:

```powershell
C:\VMs\New-ClaudeEphemeral.ps1 -Name claude-task-001
```

Create one in maintenance mode:

```powershell
C:\VMs\New-ClaudeEphemeral.ps1 -Name claude-maint-001 -Maintenance
```

Check running VMs:

```powershell
Get-VM | Where-Object State -eq "Running"
```

SSH to the ephemeral VM:

```powershell
ssh -i "$env:USERPROFILE\.ssh\ai-sandbox-ed25519" sandbox@172.30.101.50
```

Important: if the template uses static IP `172.30.101.50`, run only one clone at a time and keep `claude-base` powered off while the ephemeral VM is running.

---

## 22. Destroy Ephemeral VMs

Create the destroy script:

```powershell
notepad C:\VMs\Remove-ClaudeEphemeral.ps1
```

Paste:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$Name
)

$ErrorActionPreference = "Stop"

$Root      = "C:\VMs\ephemeral"
$DiskDir   = "$Root\disks"
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
```

Destroy an ephemeral VM:

```powershell
C:\VMs\Remove-ClaudeEphemeral.ps1 -Name claude-task-001
```

If PowerShell blocks script execution:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\VMs\Remove-ClaudeEphemeral.ps1 -Name claude-task-001
```

---

## 23. Test SSH Connectivity

From the Windows host:

```powershell
Test-NetConnection 172.30.101.50 -Port 22
ssh -i "$env:USERPROFILE\.ssh\ai-sandbox-ed25519" sandbox@172.30.101.50
```

Expected result:

* SSH succeeds from the Windows host.
* Password login should be disabled if SSH hardening was applied.

---

## 24. Test Claude Code

Log in as the sandbox user:

```bash
su - sandbox
```

Confirm proxy variables are absent:

```bash
env | grep -i proxy
```

Expected result: no output.

Confirm hostnames resolve through `/etc/hosts`:

```bash
getent hosts api.anthropic.com
getent hosts platform.claude.com
getent hosts claude.ai
```

Run Claude Code:

```bash
claude
```

If Claude Code cannot connect:

1. Confirm `/etc/hosts` has all required Claude hostnames.
2. Confirm the resolved IP is inside `160.79.104.0/21`.
3. Confirm Hyper-V ACLs allow `160.79.104.0/21`.
4. Confirm there are no proxy environment variables.
5. Run direct curl tests with `--noproxy '*'`.
6. Temporarily use maintenance mode to determine whether the default outbound deny is responsible.

---

## 25. Useful Verification Commands

### Windows Host

Check running VMs:

```powershell
Get-VM | Where-Object State -eq "Running"
```

Check all Claude VMs:

```powershell
Get-VM | Where-Object Name -like "claude-*"
```

Check base VM:

```powershell
Get-VM -Name "claude-base"
```

Check switch:

```powershell
Get-VMSwitch -Name "fresh-claude-switch"
```

Check NAT:

```powershell
Get-NetNat -Name "fresh-claude-nat"
```

Check host-side NAT IP:

```powershell
Get-NetIPAddress -InterfaceAlias "vEthernet (fresh-claude-switch)"
```

Check Hyper-V ACLs:

```powershell
Get-VMNetworkAdapterAcl `
  -VMName "claude-base" `
  -VMNetworkAdapterName "fresh-claude-adapter"
```

Check ephemeral VM ACLs:

```powershell
Get-VMNetworkAdapterAcl -VMName "<ephemeral-vm-name>"
```

Check VM network adapter IPs reported by integration services:

```powershell
Get-VMNetworkAdapter -VMName "<vm-name>" |
  Select-Object VMName, Name, SwitchName, Status, MacAddress, IPAddresses
```

Check base VM disk:

```powershell
Get-VMHardDiskDrive -VMName "claude-base"
```

Check template disk:

```powershell
Get-Item "C:\VMs\templates\claude-base-template.vhdx"
```

### Ubuntu VM

Check IP address:

```bash
ip -4 addr
```

Check routes:

```bash
ip -4 route
```

Check SSH service:

```bash
systemctl status ssh
```

Check proxy environment:

```bash
env | grep -i proxy
```

Check Claude hostname resolution:

```bash
getent hosts api.anthropic.com
getent hosts platform.claude.com
getent hosts claude.ai
```

Check Claude API connectivity:

```bash
curl -v --noproxy '*' --connect-timeout 10 https://api.anthropic.com/
```

Check blocked access:

```bash
curl -I --connect-timeout 5 https://example.com
```

Expected in locked mode:

* Claude endpoints work.
* General internet destinations fail.
* `apt update` fails unless maintenance mode is enabled.

---

## 26. Security Notes

This setup is intended to reduce sandbox risk by applying multiple controls:

* VM isolated on an internal Hyper-V switch.
* VM outbound traffic restricted with Hyper-V VM network adapter ACLs.
* Claude/Anthropic traffic allowed only by IP range.
* General outbound traffic denied in locked mode.
* Maintenance mode must be explicitly enabled for package installs or updates.
* Sandbox user is non-root.
* SSH password login can be disabled.
* Ephemeral VMs use disposable differencing disks and can be destroyed after a task.

Important limitations:

* Hyper-V VM network adapter ACLs are IP/CIDR based, not FQDN based.
* `/etc/hosts` pinning can become stale if Claude endpoint IPs change.
* Normal outbound DNS is blocked in locked mode unless explicitly allowed.
* If the VM is compromised, anything permitted by the ACL is still reachable.
* Static VM IPs should be protected from accidental reuse.
* Do not run multiple clones with the same static IP at the same time.
* Sensitive host directories should not be mounted into the VM unless required.
* Do not run the sandbox user with unnecessary sudo rights.

---

## 27. Final Expected State

At the end of this setup:

* `claude-base` is running Ubuntu.
* The VM has IP `172.30.101.50`.
* The Windows host NAT interface has IP `172.30.101.1`.
* SSH works from the Windows host to the VM.
* The VM has no proxy environment variables.
* Claude hostnames are pinned in `/etc/hosts`.
* The VM can reach Claude/Anthropic endpoints in `160.79.104.0/21`.
* The VM cannot reach general internet destinations in locked mode.
* `C:\VMs\Set-ClaudeVMNetworkMode.ps1` toggles locked and maintenance modes.
* `C:\VMs\templates\claude-base-template.vhdx` is the read-only template disk.
* Ephemeral VMs can be created from the template and destroyed after use.
* Claude Code runs as a non-root sandbox user.