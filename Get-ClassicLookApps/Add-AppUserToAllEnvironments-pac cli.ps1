<#
.SYNOPSIS
    Adds an application user with System Administrator role to all Power Platform environments.

.DESCRIPTION
    This script uses the Power Platform CLI (pac) to add an application user (service principal) 
    to all environments with the System Administrator role. It will install the pac CLI if not already present.

.PARAMETER ClientId
    The Application (client) ID of the app registration that should get the System Administrator role.

.PARAMETER RoleName
    The role name to assign to the application user. Default: "System Administrator"

.PARAMETER SkipPacInstallCheck
    Skip checking for and installing pac CLI if not present. Use this if pac CLI is already installed.

.PARAMETER OutputCsvPath
    Optional path to export results to a CSV file.

.PARAMETER EnvironmentFilter
    Optional array of environment IDs/names to filter. Only matching environments will be processed.

.EXAMPLE
    .\Add-AppUserToAllEnvironments-pac cli.ps1 -ClientId "12345678-1234-1234-1234-123456789012"

.EXAMPLE
    .\Add-AppUserToAllEnvironments-pac cli.ps1 -ClientId "12345678-1234-1234-1234-123456789012" -RoleName "System Customizer"

.EXAMPLE
    .\Add-AppUserToAllEnvironments-pac cli.ps1 -ClientId "12345678-1234-1234-1234-123456789012" -OutputCsvPath "C:\Logs\AppUserAssignments.csv"

.EXAMPLE
    .\Add-AppUserToAllEnvironments-pac cli.ps1 -ClientId "12345678-1234-1234-1234-123456789012" -EnvironmentFilter @("env-123", "env-456")
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,
    
    [Parameter(Mandatory = $false)]
    [string]$RoleName = "System Administrator",
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipPacInstallCheck,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath,
    
    [Parameter(Mandatory = $false)]
    [string[]]$EnvironmentFilter
)

# Check to see if pac cli is installed, install if not
if (-not $SkipPacInstallCheck) {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        Write-Host "pac CLI not found. Installing..." -ForegroundColor Yellow
        dotnet tool install --global Microsoft.PowerApps.CLI.Tool
    }
    else {
        Write-Host "pac CLI is already installed." -ForegroundColor Green
    }
}

# Connect to Power Platform
Write-Host "Authenticating to Power Platform..." -ForegroundColor Cyan
pac auth create 

# Get all environments as JSON and parse to objects
Write-Host "Retrieving environments..." -ForegroundColor Cyan
$environmentsJson = pac env list --json | ConvertFrom-Json

# Apply environment filter if specified
if ($EnvironmentFilter) {
    Write-Host "Filtering environments by: $($EnvironmentFilter -join ', ')" -ForegroundColor Cyan
    $environmentsJson = $environmentsJson | Where-Object { 
        $envId = $_.OrganizationId
        $EnvironmentFilter | Where-Object { $envId -like "*$_*" }
    }
}

Write-Host "Found $($environmentsJson.Count) environment(s)`n" -ForegroundColor Green

# Track results
$successCount = 0
$results = [System.Collections.Generic.List[Object]]::new()

# Add application user to each environment with admin role
$currentIndex = 0
foreach ($env in $environmentsJson) {
    $currentIndex++
    Write-Host "[$currentIndex/$($environmentsJson.Count)] Processing: $($env.FriendlyName)" -ForegroundColor Cyan
    
    try {
        pac admin assign-user `
            --environment $env.OrganizationId `
            --user $ClientId `
            --role $RoleName `
            --application-user
        
        Write-Host "  Success" -ForegroundColor Green
        $successCount++
        
        $results.Add([PSCustomObject]@{
            Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            EnvironmentName = $env.FriendlyName
            EnvironmentId   = $env.OrganizationId
            ClientId        = $ClientId
            RoleName        = $RoleName
            Status          = "Success"
            Error           = ""
        })
    }
    catch {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        
        $results.Add([PSCustomObject]@{
            Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            EnvironmentName = $env.FriendlyName
            EnvironmentId   = $env.OrganizationId
            ClientId        = $ClientId
            RoleName        = $RoleName
            Status          = "Failed"
            Error           = $_.Exception.Message
        })
    }
}

# Export to CSV if path provided
if ($OutputCsvPath) {
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation
    Write-Host "\nResults exported to: $OutputCsvPath" -ForegroundColor Green
}

# Display summary
$failedCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host "`n" 
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Total Environments: $($results.Count)" -ForegroundColor White
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })

if ($failedCount -gt 0) {
    Write-Host "\nFailed Environments:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq "Failed" } | Select-Object EnvironmentName, EnvironmentId, Error | Format-Table -AutoSize
}