<#
.SYNOPSIS
    Azure Update Manager diagnostics script that runs on the affected host via Invoke-AzVmRunCommand

.NOTES 
    Version: 1.0
#>


# Initialize results array as empty array of objects to allow array items of multiple different types.
$results = @() -as [System.Object[]]

# === results[0] - CPU Usage ===
$cpuUsage = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$results += $cpuUsage

# === results[1] - Total Provisioned Memory ===
$memoryTotal = (Get-WmiObject -Class WIN32_OperatingSystem).TotalVisibleMemorySize
$results += $memoryTotal

# === results[2] - Total Used Memory ===
$memoryFree = (Get-WmiObject -Class WIN32_OperatingSystem).FreePhysicalMemory
$memoryUsed = $memoryTotal - $memoryFree
$results += $memoryUsed

# === results[3] - Total Provisioned Memory ===


Write-Host ($results | ConvertTo-Json)