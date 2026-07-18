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

# === results[3] - WUpdate Error Codes ===
$Since = (Get-Date).AddHours(-24)
$errorsRaw = @() -as [System.Object[]]

Get-WinEvent -LogName Microsoft-Windows-WindowsUpdateClient/Operational |
Where-Object {
    $_.LevelDisplayName -eq "Error" -and
    $_.TimeCreated -ge $Since
} |
ForEach-Object { 
	$_.Message | Select-String -Pattern '0x[0-9A-Fa-f]{8}' -AllMatches |
	ForEach-Object {
		$errorCode = $_.Matches.Value

		if ($errorsRaw -notcontains $errorCode){
			$errorsRaw += $errorCode
		}
	}
}

$results += ($errorsRaw | ConvertTo-Json)

Write-Host ($results | ConvertTo-Json)