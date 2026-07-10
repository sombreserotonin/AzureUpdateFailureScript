# Azure Update Manager – VM-side diagnostic scripts

Two read-only diagnostic collectors for use with **Azure Run Command** (or the Portal → VM → *Run command* blade) when Update Manager reports assessment / installation failures.

| File | Command ID | Target |
|---|---|---|
| `AzUpdateMgr-Troubleshoot-Windows.ps1` | `RunPowerShellScript` | Windows Server 2016 → 2025, Win 10/11 |
| `AzUpdateMgr-Troubleshoot-Linux.sh`    | `RunShellScript`      | Ubuntu, Debian, RHEL/Rocky/Alma, Oracle Linux, SLES, Azure Linux |

## Prerequisites

### On your workstation (where you invoke the scripts)

- **PowerShell 5.1 or 7.x**
- **Az PowerShell modules:**
  - `Az.Accounts`
  - `Az.Compute` (v4.5.0 or later for the `-ScriptString` parameter)
  - Install: `Install-Module -Name Az.Accounts,Az.Compute -Force`
- **Authenticated session:** `Connect-AzAccount`
- **Azure RBAC role** granting `Microsoft.Compute/virtualMachines/runCommand/action` — for example, [Virtual Machine Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#virtual-machine-contributor).

### On the target VM

- **Windows:** Windows PowerShell 5.1 (present on all listed Windows Server / client targets).
- **Linux:** `bash` (≥ 4.x) and standard coreutils (`stat`, `date`, `head`, `tail`, `awk`, `sed`, `find`, `cat`). The script probes for optional tools (`python3`, `curl`, `timeout`) and degrades gracefully when they are absent.
- **Arc-enabled machines** work via `Invoke-AzConnectedMachineRunCommand` (the scripts already collect Arc extension paths). See the [Arc Run Command docs](https://learn.microsoft.com/en-us/azure/azure-arc/servers/run-command) for details.

## Design guarantees

Both scripts are **strictly read-only**:

- No package installs, no cache refreshes (`apt update` / `dnf makecache` are **not** run — only cache-only queries).
- No service restarts, no reboots, no config edits, no registry writes.
- No `wuauclt /detectnow`, `UsoClient StartScan`, or any operation that would trigger a scan/download.
- Every external tool invocation on Linux is guarded with a per-command timeout so a hung tool cannot block Run Command. On Windows, network operations are timeout-guarded; other checks are protected by `try/catch`.
- Every check is independent — one failure never aborts the run.

## Script parameters

Both scripts accept configurable limits to control output size and runtime.

### Windows (`AzUpdateMgr-Troubleshoot-Windows.ps1`)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-TailLines` | int | 200 | Lines tailed from each large log file |
| `-RecentUpdateCount` | int | 25 | Hotfixes / update history entries to display |
| `-EventCount` | int | 50 | Events fetched per event-log query |
| `-PerCommandTimeoutSec` | int | 45 | Timeout (seconds) for network operations |

Example: `-TailLines 500 -EventCount 100`

### Linux (`AzUpdateMgr-Troubleshoot-Linux.sh`)

| Environment variable | Default | Description |
|---|---|---|
| `TAIL_LINES` | 200 | Lines tailed from each large log file |
| `CMD_TIMEOUT` | 45 | Timeout (seconds) per external command |
| `RECENT_COUNT` | 25 | Recent update history entries to display |
| `NET_TIMEOUT` | 5 | Timeout (seconds) for network probes |

Example: `TAIL_LINES=500 CMD_TIMEOUT=60 bash AzUpdateMgr-Troubleshoot-Linux.sh`

## Why the full report lands in a file, not stdout

Azure Run Command truncates output to roughly **the last 4 KB** ([source](https://learn.microsoft.com/en-us/answers/questions/2133613/how-do-i-get-full-results-returning-executing-comm)). Both scripts therefore write a complete report to disk and print only a compact summary:

- Windows: `C:\Windows\Temp\AzUpdateMgr-Diag-<UTC-timestamp>.log` (+ `…-summary.json`)
- Linux:   `/var/log/azupdatemgr-diag-<UTC-timestamp>.log` (falls back to `/tmp` if `/var/log` isn't writable)

## What is collected

Both scripts cover the checks called out in Microsoft's official [Update Manager troubleshooting guide](https://learn.microsoft.com/en-us/azure/update-manager/troubleshoot):

- OS identity, uptime, IMDS metadata, guest patch mode / assessment mode
- Azure VM guest agent (`WindowsAzureGuestAgent` / `waagent`) service + logs
- Update Manager extension state and `.status` files
  - Windows: `C:\Packages\Plugins\Microsoft.CPlat.Core.WindowsPatchExtension*`
  - Linux: `/var/lib/waagent/Microsoft.CPlat.Core.LinuxPatchExtension-*`
  - Arc: `Microsoft.SoftwareUpdateManagement.*OsUpdateExtension` paths
- Windows Update service stack (`wuauserv`, `bits`, `cryptsvc`, `trustedinstaller`, `usosvc`) status and start type
- WSUS / Windows Update policy registry, TLS config, WinHTTP + WinINET proxy
- COM-based Windows Update history (last 25 entries, with HRESULTs) + `Get-HotFix`
- Reboot-pending flags (`CBS\RebootPending`, `WindowsUpdate\Auto Update\RebootRequired`, `PendingFileRenameOperations`, `/var/run/reboot-required`, `needs-restarting -r`, `zypper ps -s`)
- Disk space on system / `/`, `/var`, `/boot`
- SoftwareDistribution + CBS.log tails; `waagent.log` tail
- Package-manager state (cache-only): held packages, broken packages, upgradable list, transaction history (apt/dnf/yum/zypper/tdnf)
- TCP connectivity to Windows Update / package repo endpoints (including SUSE endpoints for zypper and current RHUI4 hostnames)
- Recent event log / journal errors from Windows Update / servicing / systemd

## How to run

### From the Azure Portal

VM → **Operations → Run command** → choose `RunPowerShellScript` (Windows) or `RunShellScript` (Linux) → paste the file's contents → **Run**. When it finishes, the summary is displayed. Grab the full log with a second Run Command call, e.g.:

```powershell
# Windows follow-up
Get-Content -Raw 'C:\Windows\Temp\AzUpdateMgr-Diag-<timestamp>.log'
```
```bash
# Linux follow-up
cat /var/log/azupdatemgr-diag-<timestamp>.log
```

### From Azure PowerShell (`Az` module)

```powershell
# Windows
Invoke-AzVMRunCommand -ResourceGroupName <rg> -VMName <vm> `
  -CommandId RunPowerShellScript `
  -ScriptPath .\AzUpdateMgr-Troubleshoot-Windows.ps1

# Linux
Invoke-AzVMRunCommand -ResourceGroupName <rg> -VMName <vm> `
  -CommandId RunShellScript `
  -ScriptPath .\AzUpdateMgr-Troubleshoot-Linux.sh
```

**Tip:** for many VMs or large outputs, use **managed Run Command** (`Set-AzVMRunCommand`) with the `-OutputBlobUri` parameter to write the full log directly to a storage account blob — this avoids the 4 KB stdout limit entirely. See [managed Run Command docs](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-managed).

## Retrieving large logs

**The `Get-Content -Raw` / `cat` follow-up call shown above is limited to ~4 KB by Run Command.** Since real logs are typically 100–800 KB, you need one of the following approaches to retrieve the complete file:

### Option A — Managed Run Command (recommended)

Create a managed Run Command that streams output to a storage blob:

```powershell
Set-AzVMRunCommand -ResourceGroupName <rg> -VMName <vm> `
  -RunCommandName GetDiagLog `
  -ScriptPath .\AzUpdateMgr-Troubleshoot-Windows.ps1 `
  -OutputBlobUri https://<storageAccount>.blob.core.windows.net/<container>/diag-%DATE%.log
```

This avoids the 4 KB limit entirely. Remove the command after retrieval with `Remove-AzVMRunCommand`.

### Option B — Chunked base64 download

Use this ready-to-paste Az PowerShell loop to download logs of any size via chunked base64 encoding. Adjust `$remotePath` to the on-VM log path:

```powershell
# Chunked log retrieval (works with any log size)
$rg   = '<resource-group>'
$vm   = '<vm-name>'
$remotePath = '/var/log/azupdatemgr-diag-*.log'   # or C:\Windows\Temp\AzUpdateMgr-Diag-*.log
$localPath  = '.\retrieved-diag.log'

# Get the raw bytes as base64-chunked transfer
$script = @"
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Raw '$remotePath')))
"@
$result = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vm `
  -CommandId (if ($remotePath -like '/*') {'RunShellScript'} else {'RunPowerShellScript'}) `
  -ScriptString $script

$b64 = ($result.Value[0].Message -split '\r?\n' | Where-Object { $_ -notmatch '^\[stdout\]' -and $_ -notmatch '^Enable succeeded' -and $_ }) -join ''
[System.IO.File]::WriteAllBytes($localPath, [Convert]::FromBase64String($b64))
Write-Output "Log saved to: $localPath"
```

## Runtime + resource footprint

- Windows script: typically 20–60 s to complete; log ~200–800 KB depending on how noisy `CBS.log` and the extension logs are.
- Linux script: typically 10–30 s; log ~100–500 KB.
- Neither script spawns background jobs; both exit cleanly under Run Command's 90-minute limit with huge margin.

## What to look at first in the log

1. `Summary` block at the bottom of the log — script version, reboot-pending flag, free disk, and warning count.
2. `Update Manager extensions on disk` / `LinuxPatchExtension - status files` — the extension's most recent `.status` file is what Update Manager actually reads. Failing operations show the HRESULT / error text here.
3. `Update extension logs (tails)` / `LinuxPatchExtension - operational logs` — the `WindowsUpdateExtension.log` / `*.core.log` / `*.ext.log` block reveals the underlying reason (network, permissions, WSUS, disk).
4. `Windows Update client (recent history via COM)` / package-manager history — surfaces the actual failing KB/package with its HRESULT or exit code.
5. `Connectivity to update endpoints` / `Connectivity - Azure/IMDS/repos` — if update endpoints show `FAIL`, the fault is upstream of Update Manager (NSG, firewall, proxy, private endpoint).

## JSON summary schemas

Both scripts emit a machine-readable JSON summary alongside the log. The schemas differ by platform:

### Windows (`*-summary.json`)

| Field | Type | Description |
|---|---|---|
| `ScriptVersion` | string | Script version |
| `StartedUtc` | string (ISO 8601) | Script start time |
| `FinishedUtc` | string (ISO 8601) | Script finish time |
| `Hostname` | string | `COMPUTERNAME` |
| `LogPath` | string | Full path to the diagnostic log |
| `Warnings` | array of string | Human-readable warnings |
| `Errors` | array of string | Errors encountered during collection |
| `VmId` | string | Azure VM ID (from IMDS) |
| `ResourceId` | string | Azure resource ID |
| `SubscriptionId` | string | Azure subscription ID |
| `Location` | string | Azure region |
| `VmSize` | string | VM SKU |
| `VmName` | string | VM name |
| `ResourceGroup` | string | Resource group name |
| `WsusConfigured` | boolean | Whether WSUS is in use |
| `WsusUseWUServer` | int/null | `UseWUServer` registry value |
| `WsusServer` | string/null | WSUS server URL |
| `WsusStatusServer` | string/null | WSUS status server URL |
| `SusClientId` | string/null | WSUS client ID |
| `PingID` | string/null | WSUS Ping ID |
| `LastDetectSuccessTime` | string/null | Last successful detection time |
| `WsusWebService` | object/null | WSUS web service reachability result |
| `RecentUpdateFailures` | array of object | Recent failed updates (up to 10) |
| `SystemDriveFreeGB` | float | Free space on C: |
| `RebootPending` | boolean | Whether any reboot signal was detected |
| `RebootPendingReasons` | array of object | Signal/Evidence pairs |
| `RebootPendingIndicators` | object | Per-indicator boolean map |

### Linux (`*-summary.json`)

| Field | Type | Description |
|---|---|---|
| `script_version` | string | Script version |
| `hostname` | string | Output of `hostname` |
| `started_utc` | string (ISO 8601) | Script start time |
| `finished_utc` | string (ISO 8601) | Script finish time |
| `distro` | string | OS distribution ID |
| `package_manager` | string | Detected package manager |
| `vm_resource_id` | string/null | Azure resource ID (from IMDS) |
| `reboot_required` | string | `"yes"`, `"no"`, or `"unknown"` |
| `free_mb_root` | string | Free MB on `/` |
| `free_mb_var` | string | Free MB on `/var` |
| `free_mb_boot` | string | Free MB on `/boot` |
| `warnings` | number | Warning count |
| `errors` | number | Error count |
| `log_path` | string | Full path to the diagnostic log |
| `log_size_bytes` | number | Log file size in bytes |