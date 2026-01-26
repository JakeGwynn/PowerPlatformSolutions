<#
.SYNOPSIS
    Retrieves Power Apps with Classic Look settings from Dataverse environments.

.DESCRIPTION
    This script queries Dataverse environments to find model-driven apps and their "New Look" settings.
    It reports both environment-level defaults and app-specific settings.
    Output files are automatically named with a timestamp: ClassicLookApps_YYYYMMDD_HHmmss_Apps.csv and ClassicLookApps_YYYYMMDD_HHmmss_Environments.csv

.PARAMETER TenantId
    The Azure AD Tenant ID.

.PARAMETER ClientId
    The Azure AD App Registration Client ID.

.PARAMETER ClientSecret
    The Azure AD App Registration Client Secret.

.PARAMETER CloudEnvironment
    The cloud environment to connect to. Valid values: Commercial, GCC, GCCHigh.

.PARAMETER EnvironmentFilter
    Optional filter for environment ID/name. Only environments matching this filter will be processed.

.PARAMETER OutputFolder
    The folder path where CSV files will be saved.

.PARAMETER FullOutput
    Optional switch. If specified, displays full app and environment tables. By default, only summary is shown.

.EXAMPLE
    .\Get-ClassicLookApps-AppRegAuth.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-secret" -CloudEnvironment Commercial -OutputFolder "C:\Reports"

.EXAMPLE
    .\Get-ClassicLookApps-AppRegAuth.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-secret" -CloudEnvironment GCC -OutputFolder "C:\Reports" -FullOutput

.EXAMPLE
    .\Get-ClassicLookApps-AppRegAuth.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-secret" -CloudEnvironment GCCHigh -OutputFolder "C:\Reports" -EnvironmentFilter "prod" -FullOutput
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet("Commercial", "GCC", "GCCHigh")]
    [string]$CloudEnvironment = "Commercial",
    
    [Parameter(Mandatory = $false)]
    [string]$EnvironmentFilter = $null,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputFolder,
    
    [Parameter(Mandatory = $false)]
    [switch]$FullOutput
)

# ===========================================================================================
# Configuration & Initialization
# ===========================================================================================

# Constants
$API_VERSION = "2023-06-01"
$DATAVERSE_API_VERSION = "v9.2"
$NEW_LOOK_SETTING = "NewLookOptOut"

# Initialize result collections (using generic lists for better performance)
$appResults = [System.Collections.Generic.List[Object]]::new()
$environmentResults = [System.Collections.Generic.List[Object]]::new()
$failedEnvironments = [System.Collections.Generic.List[Object]]::new()

# Normalize CSV output paths
$OutputFolder = $OutputFolder.TrimEnd('\', '/')
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

# Auto-generate file names with timestamp
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$baseFileName = "ClassicLookApps_$timestamp"
$appsOutputPath = Join-Path $OutputFolder "$baseFileName`_Apps.csv"
$environmentsOutputPath = Join-Path $OutputFolder "$baseFileName`_Environments.csv"

# ===========================================================================================
# Helper Functions
# ===========================================================================================

function Get-AuthToken {
    param(
        [string]$ResourceUrl,
        [string]$LoginEndpoint
    )
    
    $tokenEndpoint = "$LoginEndpoint/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "$ResourceUrl/.default"
        grant_type    = "client_credentials"
    }
    
    $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType "application/x-www-form-urlencoded"
    return $response.access_token
}

# ===========================================================================================
# Main Script
# ===========================================================================================

Write-Host "`n=== Power Apps Classic Look Settings Analyzer ===" -ForegroundColor Cyan

# Configure endpoints based on cloud environment
$loginEndpoint = switch ($CloudEnvironment) {
    "GCCHigh" { "https://login.microsoftonline.us" }
    default   { "https://login.microsoftonline.com" }
}

$powerPlatformApiEndpoint = switch ($CloudEnvironment) {
    { $_ -in "GCC", "GCCHigh" } { "https://api.gov.powerplatform.microsoft.us" }
    default { "https://api.bap.microsoft.com" }
}

Write-Host "Cloud Environment: $CloudEnvironment" -ForegroundColor Gray
Write-Host "API Endpoint: $powerPlatformApiEndpoint`n" -ForegroundColor Gray

# Get Power Platform API token
$powerPlatformToken = Get-AuthToken -ResourceUrl $powerPlatformApiEndpoint -LoginEndpoint $loginEndpoint

# Get all environments
$powerPlatformHeaders = @{
    "Authorization" = "Bearer $powerPlatformToken"
    "Accept"        = "application/json"
}

# Try admin endpoint first, fallback to non-admin endpoint if forbidden
$adminEndpoint = "$powerPlatformApiEndpoint/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=$API_VERSION"
$userEndpoint = "$powerPlatformApiEndpoint/providers/Microsoft.BusinessAppPlatform/environments?api-version=$API_VERSION"

try {
    Write-Host "Attempting admin API endpoint..." -ForegroundColor Gray
    $environmentsResponse = Invoke-RestMethod -Method GET -Uri $adminEndpoint -Headers $powerPlatformHeaders
    Write-Host "Successfully retrieved environments using admin endpoint" -ForegroundColor Green
}
catch {
    if ($_.Exception.Response.StatusCode -eq 'Forbidden' -or $_.Exception.Message -match 'Forbidden') {
        Write-Host "Admin endpoint access denied. Falling back to non-admin endpoint..." -ForegroundColor Yellow
        Write-Host "Note: Non-admin endpoint only returns environments where the app is registered as an Application User." -ForegroundColor Yellow
        $environmentsResponse = Invoke-RestMethod -Method GET -Uri $userEndpoint -Headers $powerPlatformHeaders
        Write-Host "Successfully retrieved environments using non-admin endpoint" -ForegroundColor Green
    }
    else {
        throw $_
    }
}

# Apply environment filter if specified
$environmentsToProcess = if ($EnvironmentFilter) {
    Write-Host "Filtering by environment ID/name: $EnvironmentFilter" -ForegroundColor Cyan
    $environmentsResponse.value | Where-Object { $_.name -like "*$EnvironmentFilter*" }
}
else {
    $environmentsResponse.value
}

$totalEnvironments = $environmentsToProcess.Count
Write-Host "Processing $totalEnvironments environment(s)`n" -ForegroundColor Green

# Process each environment
$currentIndex = 0
foreach ($environment in $environmentsToProcess) {
    $currentIndex++
    $environmentName = $environment.properties.displayName
    
    # Update progress
    $percentComplete = ($currentIndex / $totalEnvironments) * 100
    Write-Progress -Activity "Processing Environments" `
                   -Status "[$currentIndex/$totalEnvironments] $environmentName" `
                   -PercentComplete $percentComplete
    
    Write-Host "[$currentIndex/$totalEnvironments] $environmentName" -ForegroundColor Cyan
    
    # Skip if environment doesn't have Dataverse
    if (-not $environment.properties.linkedEnvironmentMetadata.instanceApiUrl) {
        Write-Host "  Skipping - No Dataverse instance" -ForegroundColor Gray
        continue
    }
    
    $dataverseApiUrl = $environment.properties.linkedEnvironmentMetadata.instanceApiUrl + "/api/data/$DATAVERSE_API_VERSION/"
    
    try {
        # Get Dataverse token
        $dataverseToken = Get-AuthToken -ResourceUrl $environment.properties.linkedEnvironmentMetadata.instanceApiUrl `
                                         -LoginEndpoint $loginEndpoint
        
        $dataverseHeaders = @{
            "Authorization"    = "Bearer $dataverseToken"
            "Accept"           = "application/json"
            "OData-MaxVersion" = "4.0"
            "OData-Version"    = "4.0"
        }
        
        # Get New Look setting definition
        $settingDefs = Invoke-RestMethod -Method GET -Uri ($dataverseApiUrl + "settingdefinitions") -Headers $dataverseHeaders
        $newLookSetting = $settingDefs.value | Where-Object { $_.displayname -eq "New look for model driven apps" } | Select-Object -First 1
        
        # Get environment-level New Look setting
        $environmentSetting = Invoke-RestMethod -Method GET `
            -Uri ($dataverseApiUrl + "RetrieveSetting(SettingName=@p1)?@p1='$NEW_LOOK_SETTING'") `
            -Headers $dataverseHeaders
        
        # Transform NewLookOptOut to NewLook: true (opt out) = enabled, false (not opt out) = disabled
        $environmentNewLookDefault = if ($environmentSetting.SettingDetail.Value -ne $null) {
            if ($environmentSetting.SettingDetail.Value -eq "true") { "Enabled" } else { "Disabled" }
        }
        else {
            "Not set"
        }
        
        Write-Host "  Environment New Look Default: $environmentNewLookDefault" -ForegroundColor Gray
        
        # Query apps
        $apps = Invoke-RestMethod -Method GET -Uri ($dataverseApiUrl + "appmodules") -Headers $dataverseHeaders
        Write-Host "  Found $($apps.value.Count) app(s)" -ForegroundColor Gray
        
        # Process each app
        foreach ($app in $apps.value) {
            try {
                # Get app-specific settings
                $appSettings = Invoke-RestMethod -Method GET `
                    -Uri ($dataverseApiUrl + "appsettings?`$filter=_parentappmoduleid_value eq $($app.appmoduleid)") `
                    -Headers $dataverseHeaders
                
                # Get the setting name and value
                $settingName = if ($newLookSetting.uniquename) { $newLookSetting.uniquename } else { $newLookSetting.displayname }
                $appSetting = $appSettings.value | Where-Object { $_._settingdefinitionid_value -eq $newLookSetting.settingdefinitionid }
                
                # Transform NewLookOptOut to NewLook: true (opt out) = enabled, false (not opt out) = disabled
                $settingValue = if ($appSetting) {
                    if ($appSetting.value -eq "true") { "Enabled" } else { "Disabled" }
                }
                else {
                    "$environmentNewLookDefault (Environment Default)"
                }
            }
            catch {
                $settingName = "Error"
                $settingValue = $_.Exception.Message
            }
            
            # Build result object
            $appResults.Add([PSCustomObject]@{
                EnvironmentName = $environmentName
                EnvironmentId   = $environment.name
                AppName         = $app.name
                AppId           = $app.appmoduleid
                SolutionId      = $app.solutionid
                ClientType      = $app.clienttype
                NewLookEnabled    = $settingValue
            })
        }
        
        # Add environment-level result
        $environmentResults.Add([PSCustomObject]@{
            EnvironmentName = $environmentName
            EnvironmentId   = $environment.name
            NewLook         = $environmentNewLookDefault
        })
    }
    catch {
        Write-Warning "  Failed: $_"
        # Add failed environment to results with error in NewLook column
        $environmentResults.Add([PSCustomObject]@{
            EnvironmentName = $environmentName
            EnvironmentId   = $environment.name
            NewLook         = "ERROR: $($_.Exception.Message)"
        })
    }
}

Write-Progress -Activity "Processing Environments" -Completed

# ===========================================================================================
# Output Results
# ===========================================================================================

if ($FullOutput) {
    Write-Host "`n=== Apps Analysis ===" -ForegroundColor Yellow
    if ($appResults.Count -gt 0) {
        $appResults | Format-Table -AutoSize
    }
    else {
        Write-Host "No apps found." -ForegroundColor Gray
    }
    
    Write-Host "`n=== Environment-Level Settings ===" -ForegroundColor Yellow
    if ($environmentResults.Count -gt 0) {
        $environmentResults | Format-Table -AutoSize
    }
    else {
        Write-Host "No environments found." -ForegroundColor Gray
    }
}

# Export to CSV (always happens)
if ($appResults.Count -gt 0) {
    $appResults | Export-Csv -Path $appsOutputPath -NoTypeInformation
    Write-Host "`nApps exported to: $appsOutputPath" -ForegroundColor Green
}

if ($environmentResults.Count -gt 0) {
    $environmentResults | Export-Csv -Path $environmentsOutputPath -NoTypeInformation
    Write-Host "Environments exported to: $environmentsOutputPath" -ForegroundColor Green
}

# Calculate summary statistics
$appNewLookEnabled = @($appResults | Where-Object { $_.NewLookEnabled -eq "Enabled" }).Count
$appNewLookDisabled = @($appResults | Where-Object { $_.NewLookEnabled -eq "Disabled" }).Count
$appNewLookEnabledDefault = @($appResults | Where-Object { $_.NewLookEnabled -eq "Enabled (Environment Default)" }).Count
$appNewLookDisabledDefault = @($appResults | Where-Object { $_.NewLookEnabled -eq "Disabled (Environment Default)" }).Count
$appNewLookNotSetDefault = @($appResults | Where-Object { $_.NewLookEnabled -eq "Not set (Environment Default)" }).Count

$envNewLookEnabled = @($environmentResults | Where-Object { $_.NewLook -eq "Enabled" }).Count
$envNewLookDisabled = @($environmentResults | Where-Object { $_.NewLook -eq "Disabled" }).Count
$envNewLookNotSet = @($environmentResults | Where-Object { $_.NewLook -eq "Not set" }).Count
$envNewLookErrors = @($environmentResults | Where-Object { $_.NewLook -like "ERROR:*" }).Count

Write-Host "`n=== Summary Statistics ===" -ForegroundColor Cyan
Write-Host "`nEnvironments:" -ForegroundColor White
Write-Host "  Total Processed: $($environmentResults.Count)" -ForegroundColor Green
Write-Host "  New Look Enabled: $envNewLookEnabled" -ForegroundColor Green
Write-Host "  New Look Disabled: $envNewLookDisabled" -ForegroundColor Yellow
Write-Host "  Not Set: $envNewLookNotSet" -ForegroundColor Gray
if ($envNewLookErrors -gt 0) {
    Write-Host "  Errors: $envNewLookErrors" -ForegroundColor Red
}

Write-Host "`nApps:" -ForegroundColor White
Write-Host "  Total Analyzed: $($appResults.Count)" -ForegroundColor Green
Write-Host "  New Look Enabled - Explicit: $appNewLookEnabled" -ForegroundColor Green
Write-Host "  New Look Disabled - Explicit: $appNewLookDisabled" -ForegroundColor Yellow
Write-Host "  New Look Enabled - Default: $appNewLookEnabledDefault" -ForegroundColor Cyan
Write-Host "  New Look Disabled - Default: $appNewLookDisabledDefault" -ForegroundColor DarkYellow
Write-Host "  Not Set - Default: $appNewLookNotSetDefault" -ForegroundColor Gray

Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
