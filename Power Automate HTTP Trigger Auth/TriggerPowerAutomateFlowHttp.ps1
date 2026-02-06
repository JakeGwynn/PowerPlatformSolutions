<#
.SYNOPSIS
    Triggers a Power Automate flow via HTTP request with OAuth authentication.

.DESCRIPTION
    Uses an Azure AD App Registration (service principal) to authenticate and trigger
    a Power Automate flow that has an HTTP request trigger with OAuth enabled.

.PARAMETER TenantId
    Azure AD Tenant ID

.PARAMETER AppId
    Application (Client) ID from the App Registration

.PARAMETER ClientSecret
    Client secret value from the App Registration

.PARAMETER WebHookUri
    The HTTP POST URL from your Power Automate flow trigger

.PARAMETER RequestBody
    Optional JSON body to send with the request

.EXAMPLE
    .\TriggerPowerAutomateFlowHttp.ps1 -TenantId "xxx" -AppId "xxx" -ClientSecret "xxx" -WebHookUri "https://..."

.EXAMPLE
    .\TriggerPowerAutomateFlowHttp.ps1 -WebHookUri "https://..." -RequestBody '{"name": "test"}'

.NOTES
    See TriggerPowerAutomateFlowHttp.md for setup instructions.
    Service Principal Object ID (add to Flow's allowed users): 616ac3d9-94ee-41ce-9475-312f037168d3
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $true)]
    [string]$WebHookUri,

    [Parameter()]
    [string]$RequestBody = $null
)

# Get OAuth token
$Body = @{    
    grant_type    = "client_credentials"
    client_id     = $AppId
    client_secret = $ClientSecret
    scope         = "https://service.flow.microsoft.com//.default"
}

$TokenRequest = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $Body

$Token = $TokenRequest.access_token

$headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
}

# Trigger the flow
if ($RequestBody) {
    $response = Invoke-RestMethod -Uri $WebHookUri -Headers $headers -Method POST -Body $RequestBody
} else {
    $response = Invoke-RestMethod -Uri $WebHookUri -Headers $headers -Method POST
}

# Output response if any
if ($response) {
    $response
} else {
    Write-Host "Flow triggered successfully." -ForegroundColor Green
}