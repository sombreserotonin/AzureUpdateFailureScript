# Azure Update Manager – VM-side diagnostic scripts

Two read-only diagnostic collectors for use with **Azure Run Command** (or the Portal → VM → *Run command* blade) when Update Manager reports assessment / installation failures.

| File | Command ID | Target |
|---|---|---|
| `AzUpdateMgr-Troubleshoot-Windows.ps1` | `RunPowerShellScript` | Windows Server 2016 → 2025, Win 10/11 |
| `AzUpdateMgr-Troubleshoot-Linux.sh`    | `RunShellScript`      | Ubuntu, Debian, RHEL/Rocky/Alma, Oracle Linux, SLES, Azure Linux |

## Design guarantees

Both scripts are **strictly read-only**:

- No package installs, no cache refreshes (`apt update` / `dnf makecache` are **not** run — only cache-only queries).
- No service restarts, no reboots, no config edits, no registry writes.
- No `wuauclt /detectnow`, `UsoClient StartScan`, or any operation that would trigger a scan/download.
- Every external command is wrapped with a per-command timeout so a hung tool cannot block Run Command.
- Every check is independent — one failure never aborts the run.

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
- TCP:443 reachability to Windows Update / package repo endpoints
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

### From `az` CLI
```bash
# Windows
az vm run-command invoke \
  --resource-group <rg> --name <vm> \
  --command-id RunPowerShellScript \
  --scripts @AzUpdateMgr-Troubleshoot-Windows.ps1

# Linux
az vm run-command invoke \
  --resource-group <rg> --name <vm> \
  --command-id RunShellScript \
  --scripts @AzUpdateMgr-Troubleshoot-Linux.sh
```

Tip: if you have many VMs, use the *managed* Run Command (`az vm run-command create`) which supports larger outputs and can upload directly to a storage blob ([docs](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-managed)).

## Runtime + resource footprint

- Windows script: typically 20–60 s to complete; log ~200–800 KB depending on how noisy `CBS.log` and the extension logs are.
- Linux script: typically 10–30 s; log ~100–500 KB.
- Neither script spawns background jobs; both exit cleanly under Run Command's 90-minute limit with huge margin.

## What to look at first in the log

1. `Summary` block at the bottom of the log — reboot-pending flag, free disk, and warning count.
2. `Update Manager extensions on disk` / `LinuxPatchExtension - status files` — the extension's most recent `.status` file is what Update Manager actually reads. Failing operations show the HRESULT / error text here.
3. `Extension logs (tails)` — the `WindowsUpdateExtension.log` / `*.core.log` / `*.ext.log` block reveals the underlying reason (network, permissions, WSUS, disk).
4. `Windows Update client (recent history via COM)` / package-manager history — surfaces the actual failing KB/package with its HRESULT or exit code.
5. `Connectivity` — if update endpoints show `FAIL`, the fault is upstream of Update Manager (NSG, firewall, proxy, private endpoint).
