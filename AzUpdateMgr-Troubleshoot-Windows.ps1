<#
.SYNOPSIS
    Read-only diagnostic collector for Azure Update Manager failures on Windows VMs.

.DESCRIPTION
    Designed to be pasted into Azure Run Command (RunPowerShellScript) or the
    Portal "Run command" blade. It:
      * Makes NO changes to the VM (no service restarts, no registry edits,
        no cache resets, no reboots). Every operation is read-only.
      * Writes a full report to C:\Windows\Temp\AzUpdateMgr-Diag-<timestamp>.log
        and a machine-readable summary to ...-summary.json alongside it.
      * Prints only a compact SUMMARY to stdout, because Azure Run Command
        truncates output to roughly the last 4 KB. Pull the full log off the
        VM afterwards (see "Retrieving the log" at the bottom).
      * Guards every check with try/catch and short timeouts so a single
        broken component cannot abort the run.

.NOTES
    Author         : Generated diagnostic
    Target         : Windows Server 2016/2019/2022/2025, Windows 10/11 Azure VMs
    Privilege      : Run Command executes as SYSTEM, which is what we need.
    Idempotent     : Yes. Safe to run repeatedly.
    Side effects   : None. If you spot anything that writes outside
                     C:\Windows\Temp\AzUpdateMgr-Diag-*, treat it as a bug.
#>

[CmdletBinding()]
param(
    [int]$TailLines           = 200,   # lines to tail from each large log
    [int]$RecentUpdateCount   = 25,    # hotfixes / update history entries to show
    [int]$EventCount          = 50,    # events per event-log query
    [int]$PerCommandTimeoutSec = 45    # per-external-command timeout
)

# --- Bootstrap ---------------------------------------------------------------
$ErrorActionPreference = 'Continue'    # never let one failure kill the script
$ProgressPreference    = 'SilentlyContinue'
$startedUtc            = (Get-Date).ToUniversalTime()
$stamp                 = $startedUtc.ToString('yyyyMMdd-HHmmssZ')
$outDir                = 'C:\Windows\Temp'
$logPath               = Join-Path $outDir "AzUpdateMgr-Diag-$stamp.log"
$jsonPath              = Join-Path $outDir "AzUpdateMgr-Diag-$stamp-summary.json"
$summary               = [ordered]@{
    StartedUtc         = $startedUtc.ToString('o')
    Hostname           = $env:COMPUTERNAME
    LogPath            = $logPath
    Findings           = New-Object System.Collections.Generic.List[object]
    Warnings           = New-Object System.Collections.Generic.List[string]
    Errors             = New-Object System.Collections.Generic.List[string]
}

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Write-Section {
    param([string]$Title)
    $bar = '=' * 78
    Add-Content -LiteralPath $logPath -Value "`r`n$bar`r`n== $Title`r`n$bar" -Encoding UTF8
}

function Invoke-Safe {
    <#
        Runs a scriptblock, captures its output into the log file, and never
        throws. Adds an entry to $summary.Errors if it fails.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Script
    )
    Write-Section $Name
    Write-Log "BEGIN: $Name"
    try {
        $out = & $Script 2>&1
        if ($null -ne $out) {
            $text = ($out | Out-String).TrimEnd()
            if ($text) { Add-Content -LiteralPath $logPath -Value $text -Encoding UTF8 }
        }
    } catch {
        $msg = "ERROR in '$Name': $($_.Exception.Message)"
        Write-Log $msg 'ERROR'
        $summary.Errors.Add($msg) | Out-Null
    }
    Write-Log "END:   $Name"
}

function Get-TailFile {
    param([string]$Path, [int]$Lines = $TailLines)
    if (-not (Test-Path -LiteralPath $Path)) { return "  <not found: $Path>" }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $header = "  >> $($item.FullName)  ($([math]::Round($item.Length/1KB,1)) KB, modified $($item.LastWriteTime.ToString('s')))"
        $tail = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop
        return @($header, '  ---- tail begin ----') + ($tail | ForEach-Object { '  ' + $_ }) + '  ---- tail end ----'
    } catch {
        return "  <cannot read '$Path': $($_.Exception.Message)>"
    }
}

# --- Header ------------------------------------------------------------------
Write-Section 'Azure Update Manager - Windows diagnostic'
Write-Log ("Script started {0} UTC on {1}" -f $startedUtc, $env:COMPUTERNAME)
Write-Log  "Read-only mode. No changes will be made to this VM."

# 1. OS + machine identity ----------------------------------------------------
Invoke-Safe 'OS and hardware' {
    Get-ComputerInfo -Property `
        CsName, CsDomain, OsName, OsVersion, OsBuildNumber, OsArchitecture, `
        OsInstallDate, OsLastBootUpTime, OsUptime, CsManufacturer, CsModel, `
        WindowsProductName, WindowsInstallationType, WindowsRegisteredOrganization |
        Format-List
}

# 2. Azure instance metadata (IMDS, no auth needed, 169.254.169.254) ----------
Invoke-Safe 'Azure Instance Metadata (IMDS)' {
    try {
        $imds = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' `
            -Headers @{ Metadata = 'true' } `
            -TimeoutSec 5 -Proxy $null
        $imds | ConvertTo-Json -Depth 6
        $summary.VmId          = $imds.compute.vmId
        $summary.ResourceId    = $imds.compute.resourceId
        $summary.SubscriptionId= $imds.compute.subscriptionId
        $summary.Location      = $imds.compute.location
        $summary.VmSize        = $imds.compute.vmSize
        $summary.VmName        = $imds.compute.name
        $summary.ResourceGroup = $imds.compute.resourceGroupName
    } catch {
        "IMDS unreachable: $($_.Exception.Message)"
    }
}

# 3. VM agent (WindowsAzureGuestAgent) health ---------------------------------
Invoke-Safe 'Azure VM Guest Agent' {
    $svcs = @('WindowsAzureGuestAgent','RdAgent','WindowsAzureNetAgentSvc')
    Get-Service -Name $svcs -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize

    $agentDir = 'C:\WindowsAzure\Packages'
    if (Test-Path $agentDir) {
        Get-ChildItem $agentDir -Filter 'GuestAgent_*' -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3 Name, LastWriteTime | Format-Table -AutoSize
    }

    $aggregate = 'C:\WindowsAzure\Logs\AggregateStatus'
    Get-TailFile -Path $aggregate -Lines 80
}

# 4. Update Manager extension state ------------------------------------------
Invoke-Safe 'Update Manager extensions on disk' {
    $pluginRoot = 'C:\Packages\Plugins'
    if (-not (Test-Path $pluginRoot)) {
        "  <no C:\Packages\Plugins directory - VM agent may never have installed extensions>"
        return
    }
    $wanted = @(
        'Microsoft.CPlat.Core.WindowsPatchExtension',
        'Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension',
        'Microsoft.CPlat.Core.RunCommandHandlerWindows',
        'Microsoft.CPlat.Core.RunCommandWindows'
    )
    foreach ($ext in $wanted) {
        $matches = Get-ChildItem $pluginRoot -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like "$ext*" }
        if (-not $matches) { "  <not installed: $ext>"; continue }
        foreach ($m in $matches) {
            "  {0}   (modified {1})" -f $m.FullName, $m.LastWriteTime
            $statusDir = Join-Path $m.FullName 'Status'
            if (Test-Path $statusDir) {
                Get-ChildItem $statusDir -Filter *.status -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
                    ForEach-Object {
                        "    status file: $($_.Name)  ($($_.LastWriteTime))"
                        try {
                            $raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
                            ($raw | ConvertFrom-Json -ErrorAction Stop) |
                                ConvertTo-Json -Depth 8
                        } catch {
                            "    (could not parse: $($_.Exception.Message))"
                        }
                    }
            }
        }
    }
}

Invoke-Safe 'Update extension logs (tails)' {
    $extLogRoot = 'C:\WindowsAzure\Logs\Plugins'
    if (-not (Test-Path $extLogRoot)) {
        "  <no $extLogRoot directory>"
        return
    }
    $extDirs = Get-ChildItem $extLogRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Patch|Update|Software' }
    foreach ($d in $extDirs) {
        "  ---- $($d.FullName) ----"
        Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.log$|\.txt$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 6 |
            ForEach-Object { Get-TailFile -Path $_.FullName -Lines $TailLines }
    }
    # Azure Arc-enabled servers path
    $arcLogs = 'C:\ProgramData\GuestConfig\extension_logs\Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension'
    if (Test-Path $arcLogs) {
        "  ---- Arc: $arcLogs ----"
        Get-ChildItem $arcLogs -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 6 |
            ForEach-Object { Get-TailFile -Path $_.FullName -Lines $TailLines }
    }
}

# 5. Windows Update service stack + config -----------------------------------
Invoke-Safe 'Windows Update services (read-only, no restart)' {
    $svcs = 'wuauserv','bits','cryptsvc','trustedinstaller','msiserver','usosvc'
    Get-Service -Name $svcs -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
}

Invoke-Safe 'Windows Update / WSUS registry policy' {
    $keys = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update',
        'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    )
    foreach ($k in $keys) {
        "---- $k ----"
        if (Test-Path $k) {
            Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS* | Format-List
        } else { "  <key not present>" }
    }
}

# 6. Windows Update client health via COM (read-only, no scan triggered) -----
Invoke-Safe 'Windows Update client (recent history via COM, read-only)' {
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $total    = 0
        try { $total = $searcher.GetTotalHistoryCount() } catch { $total = 0 }
        "Total history entries known to Windows Update client: $total"
        if ($total -gt 0) {
            $take = [Math]::Min($RecentUpdateCount, $total)
            $hist = $searcher.QueryHistory(0, $take)
            $rows = for ($i = 0; $i -lt $hist.Count; $i++) {
                $h = $hist.Item($i)
                [pscustomobject]@{
                    Date        = $h.Date
                    Operation   = switch ($h.Operation) { 1 {'Install'} 2 {'Uninstall'} default {"Op$($h.Operation)"} }
                    ResultCode  = switch ($h.ResultCode) {
                                    0 {'NotStarted'} 1 {'InProgress'} 2 {'Succeeded'}
                                    3 {'SucceededWithErrors'} 4 {'Failed'} 5 {'Aborted'}
                                    default {"Code$($h.ResultCode)"}
                                  }
                    HResult     = ('0x{0:X8}' -f ($h.HResult -band 0xFFFFFFFF))
                    Title       = $h.Title
                }
            }
            $failed = $rows | Where-Object { $_.ResultCode -in 'Failed','SucceededWithErrors','Aborted' }
            $summary.RecentUpdateFailures = $failed | Select-Object -First 10
            $rows | Format-Table -AutoSize -Wrap
        }
    } catch {
        "Update COM API unavailable: $($_.Exception.Message)"
    }
}

Invoke-Safe 'Installed hotfixes (last set)' {
    Get-HotFix -ErrorAction SilentlyContinue |
        Sort-Object InstalledOn -Descending |
        Select-Object -First $RecentUpdateCount HotFixID, Description, InstalledOn, InstalledBy |
        Format-Table -AutoSize
}

# 7. Reboot pending check (registry only, no reboot) --------------------------
Invoke-Safe 'Pending reboot flags' {
    $checks = @{
        'Component Based Servicing' = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'Windows Update AU'         = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'PendingFileRenameOps'      = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        'Pending computer rename'   = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName -ne
                                       (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName)
    }
    $checks.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Check = $_.Key; Pending = [bool]$_.Value }
    } | Format-Table -AutoSize
    $summary.RebootPending = ($checks.Values | Where-Object { $_ }) -ne $null
}

# 8. Disk space (system drive + all fixed) -----------------------------------
Invoke-Safe 'Disk space (fixed drives)' {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Select-Object DeviceID,
            @{n='SizeGB';   e={[math]::Round($_.Size/1GB,1)}},
            @{n='FreeGB';   e={[math]::Round($_.FreeSpace/1GB,1)}},
            @{n='FreePct';  e={[math]::Round(($_.FreeSpace / [math]::Max($_.Size,1)) * 100,1)}} |
        Format-Table -AutoSize
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($c) {
        $summary.SystemDriveFreeGB = [math]::Round($c.FreeSpace/1GB,1)
        if ($summary.SystemDriveFreeGB -lt 5) {
            $summary.Warnings.Add("C: has less than 5 GB free ($($summary.SystemDriveFreeGB) GB). Windows Update needs headroom.") | Out-Null
        }
    }
}

# 9. SoftwareDistribution & CBS log sizes (do NOT clear them) ----------------
Invoke-Safe 'SoftwareDistribution + CBS state' {
    $sd = 'C:\Windows\SoftwareDistribution'
    if (Test-Path $sd) {
        $size = (Get-ChildItem $sd -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        "SoftwareDistribution size: $([math]::Round($size/1MB,1)) MB"
        Get-ChildItem $sd -Directory -ErrorAction SilentlyContinue |
            Select-Object Name, LastWriteTime | Format-Table -AutoSize
    }
    $wuLog  = 'C:\Windows\WindowsUpdate.log'
    $cbsLog = 'C:\Windows\Logs\CBS\CBS.log'
    Get-TailFile -Path $wuLog  -Lines 80
    Get-TailFile -Path $cbsLog -Lines 120
}

# 10. Network path to update endpoints ---------------------------------------
Invoke-Safe 'Connectivity to update endpoints (TCP 443, DNS only)' {
    $endpoints = @(
        'download.windowsupdate.com',
        'update.microsoft.com',
        'sls.update.microsoft.com',
        'fe3.delivery.mp.microsoft.com',
        'management.azure.com',
        'login.microsoftonline.com',
        'guestnotificationservice.azure.com'
    )
    $endpoints | ForEach-Object {
        $e = $_
        try {
            $t = Test-NetConnection -ComputerName $e -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
            [pscustomobject]@{ Endpoint = $e; TCP443 = $t }
        } catch {
            [pscustomobject]@{ Endpoint = $e; TCP443 = "err: $($_.Exception.Message)" }
        }
    } | Format-Table -AutoSize

    "---- Proxy config (WinHTTP) ----"
    try { netsh winhttp show proxy 2>&1 } catch { $_.Exception.Message }
    "---- Proxy config (WinINET, per-user SYSTEM) ----"
    try {
        Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' `
            -ErrorAction SilentlyContinue |
            Select-Object ProxyEnable, ProxyServer, AutoConfigURL | Format-List
    } catch { $_.Exception.Message }
}

# 11. TLS + .NET (0x80072F8F et al. often boil down to TLS 1.2) --------------
Invoke-Safe 'TLS configuration' {
    $tlsKeys = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client',
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server',
        'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
    )
    foreach ($k in $tlsKeys) {
        "---- $k ----"
        if (Test-Path $k) {
            Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS* | Format-List
        } else { "  <not present>" }
    }
    "Current process security protocol: $([Net.ServicePointManager]::SecurityProtocol)"
}

# 12. Event logs relevant to updates -----------------------------------------
Invoke-Safe 'System event log - recent Windows Update / servicing errors' {
    $providers = 'Microsoft-Windows-WindowsUpdateClient','Microsoft-Windows-Servicing','Microsoft-Windows-WUSA'
    foreach ($p in $providers) {
        "---- Provider: $p ----"
        try {
            Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName=$p } `
                -MaxEvents $EventCount -ErrorAction Stop |
                Where-Object { $_.LevelDisplayName -in 'Error','Warning' -or $_.Id -in 19,20,43,44 } |
                Select-Object TimeCreated, Id, LevelDisplayName, Message |
                Format-List
        } catch {
            "  (no events / provider not found: $($_.Exception.Message))"
        }
    }
}

Invoke-Safe 'Setup log - recent CBS/servicing failures' {
    try {
        Get-WinEvent -LogName Setup -MaxEvents $EventCount -ErrorAction Stop |
            Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
            Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Format-List
    } catch { "  (no Setup events readable)" }
}

# 13. Guest patching mode / auto-assessment flags ----------------------------
Invoke-Safe 'Guest patch settings (from IMDS)' {
    try {
        $c = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-12-13' `
            -Headers @{ Metadata = 'true' } -TimeoutSec 5 -Proxy $null
        [pscustomobject]@{
            OsProfile               = $c.osProfile
            PatchMode               = $c.osProfile.windowsConfiguration.patchSettings.patchMode
            AssessmentMode          = $c.osProfile.windowsConfiguration.patchSettings.assessmentMode
            EnableHotpatching       = $c.osProfile.windowsConfiguration.patchSettings.enableHotpatching
        } | Format-List
    } catch {
        "IMDS unreachable for patch settings: $($_.Exception.Message)"
    }
}

# --- Summary block -----------------------------------------------------------
Write-Section 'Summary'
$summary.FinishedUtc = (Get-Date).ToUniversalTime().ToString('o')
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$logSize = (Get-Item $logPath).Length

# Build a ready-to-paste Az PowerShell one-liner. IMDS provides VM name + RG;
# fall back to placeholders if IMDS was unreachable (Arc / offline machines).
$vmNameForCmd = if ($summary.VmName)        { $summary.VmName }        else { '<vm-name>' }
$rgForCmd     = if ($summary.ResourceGroup) { $summary.ResourceGroup } else { '<resource-group>' }
$logLeaf      = Split-Path $logPath  -Leaf
$jsonLeaf     = Split-Path $jsonPath -Leaf
$localLog     = "C:\Temp\$logLeaf"
$localJson    = "C:\Temp\$jsonLeaf"

# Assemble the two commands as plain strings. Single-quoted segments are
# concatenated so nothing interpolates unexpectedly and there are no nested
# double quotes to escape. Inner script (run on the VM) uses single quotes
# around the path so the outer double-quoted -ScriptString works cleanly.
$q = [char]34   # literal double-quote, keeps this line free of escaping headaches
$fetchLog  = "(Invoke-AzVMRunCommand -ResourceGroupName '$rgForCmd' -Name '$vmNameForCmd' -CommandId 'RunPowerShellScript' -ScriptString $($q)Get-Content -Raw '$logPath'$($q)).Value[0].Message | Set-Content -LiteralPath '$localLog' -Encoding UTF8"
$fetchJson = "(Invoke-AzVMRunCommand -ResourceGroupName '$rgForCmd' -Name '$vmNameForCmd' -CommandId 'RunPowerShellScript' -ScriptString $($q)Get-Content -Raw '$jsonPath'$($q)).Value[0].Message | Set-Content -LiteralPath '$localJson' -Encoding UTF8"

$compact = @"
=== Azure Update Manager diag (Windows) ===
Host             : $env:COMPUTERNAME
Started (UTC)    : $($startedUtc.ToString('s'))Z
Finished (UTC)   : $($summary.FinishedUtc)
Log file         : $logPath  ($([math]::Round($logSize/1KB,1)) KB)
Summary JSON     : $jsonPath
Reboot pending?  : $($summary.RebootPending)
Free on C:       : $($summary.SystemDriveFreeGB) GB
VM Resource ID   : $($summary.ResourceId)
Detected VM/RG   : $vmNameForCmd  /  $rgForCmd
Warnings         : $($summary.Warnings.Count)
Errors captured  : $($summary.Errors.Count)

--- Retrieve from your local PowerShell (Az module) ---
Prereqs on your local PC:
    Connect-AzAccount
    New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null

# Full log:
$fetchLog

# Summary JSON:
$fetchJson

Note: Run Command truncates stdout to ~4 KB per invocation. If the log is
larger, use the base64-chunked download pattern instead of Get-Content -Raw.
"@
Write-Output $compact
