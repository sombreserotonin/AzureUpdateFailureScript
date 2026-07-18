<#
.SYNOPSIS
    Read-only diagnostic script to assist with troubleshoot Azure Update Manager failures on Windows Virtual Machines.

.NOTES 
    Version: 1.0
#>

Import-Module Az.Compute

# ==== PARAMS ====
$subscriptionId = "bdb10c9b-53ed-4281-860e-3fab0adb7008"
$resourceGroupName = "cgl-ae-dc01_group"
$vmName = "cgl-ae-dc02"

$scriptPath = "./AzUpdateMgr-HostScript-Windows.ps1"

# ==== INITIAL CONFIGURATION ==== 
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'


Write-Host " ==== Connecting to Azure Account ==== "
$ac = Connect-AzAccount -Subscription $subscriptionId *>&1

# This should not fail, as the program will just hang, but just in case I will handle null output.

if ($null -eq $ac){
    Write-Error "Error: Unable to authenticate with Azure.`n"
    exit 1
}else{
    $upn = $ac.Context.Account
    Write-Host "Successfully authenticated with Azure as $upn.`n"
}

try{
    $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction Stop
}catch{
    Write-Host "Error: Unable to find VM $vmName in $resourceGroupName."
    exit 1
}

Write-Host "==== Checking Role Assignments ===="

$contributors = Get-AzRoleAssignment -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Compute/virtualMachines/$vmName" | Where-Object { $_.RoleDefinitionName -eq "Contributor" }

$isContributor = $false

foreach ($contributor in $contributors){
    if ($contributor.SignInName -eq $upn){
        $isContributor = $true
    }
}

if ($isContributor -eq $true){
        Write-Host "Confirmed account has appropriate permissions to run script on host.`n"
    }else{
        Write-Host "Error: Account does not have permissions to run diagnostic script on host. Please PIM up to Contributor permissions for VM.`n"
        exit 1
    }

Write-Host "==== Running Script on Host ===="

try{
    $result = Invoke-AzVMRunCommand -VM $vm -ScriptPath $scriptPath -CommandId "RunPowerShellScript" -ErrorAction Stop
}catch{
    Write-Host "Error: Unable to run script on host."
    Write-Host $_
    exit 1
}

$resultOut = ($result.Value.Message | ConvertFrom-Json)
