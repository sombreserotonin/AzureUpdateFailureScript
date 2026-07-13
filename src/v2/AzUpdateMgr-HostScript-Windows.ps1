<#
.SYNOPSIS
    Azure Update Manager diagnostics script that runs on the affected host via Invoke-AzVmRunCommand

.NOTES 
    Version: 1.0
#>

$results = @() -as [System.Object[]]
# === Report CPU Usage ===

$cpuUsage = (Get-WmiObject -Class Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$results += $cpuUsage

$results += 100
$results += "test string"

Write-Host ($results | ConvertTo-Json)