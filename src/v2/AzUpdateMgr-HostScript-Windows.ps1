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
#TODO - Re-write this

$Since = (Get-Date).AddHours(-24)
$errorsRaw = @() -as [System.Object[]]

$events = Get-WinEvent -LogName Microsoft-Windows-WindowsUpdateClient/Operational -ErrorAction SilentlyContinue

if ($events){
	$events | Where-Object {
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
}else {
	$results += ""
}


# === results[4] - Extensions on disk === 
$extensions = @() -as [System.Object[]]

$extensionsDir = "C:\Packages\Plugins"
$extensionsDirExists = Test-Path -Path $extensionsDir

if ($false -eq $extensionsDirExists){
	$results += "NoDirFolder"
}else{
	$dirs = Get-ChildItem -Path $extensionsDir -Directory
	
	foreach ($dir in $dirs){
		$extensionName = $dir.Name
		
		foreach ($versionNum in (Get-ChildItem -Path $dir.FullName -Name)){
			$statusDir = "C:\Packages\Plugins\$extensionName\$versionNum\Status"
			$statusDirExists = Test-Path -Path $statusDir

			if ($false -eq $statusDirExists){
				$extensions += @{
					name = $extensionName
					version = $versionNum.ToString()
					status = "Invalid"
				}
			}else{
				$currentStatusFile = (Get-ChildItem -Path $statusDir -Filter "*.status" | Sort-Object LastWriteTime -Descending)[0].Name
				$statusJSON = (Get-Content -Raw -Path "$statusDir/$currentStatusFile") | ConvertFrom-Json
				$status = $statusJSON[0].status.status

				$extensions += @{
					name = $extensionName
					version = $versionNum.ToString()
					status = $status
				}
			}
		}
	}

	if ($extensions.Count -eq 0){
		$results += "NoExtensions"
	}else{
		$results += ConvertTo-Json $extensions
	}
}

Write-Host ($results | ConvertTo-Json)