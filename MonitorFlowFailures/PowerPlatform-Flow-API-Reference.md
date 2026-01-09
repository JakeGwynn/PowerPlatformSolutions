# Power Platform Flow API Quick Reference

## Authentication
Use OAuth 2.0 client credentials flow with scope `https://service.powerapps.com/.default`

## Get Flows from Environment
```
GET https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/{environmentId}/v2/flows?api-version=2016-11-01
```

## Get Flow Runs
```
GET https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/{environmentId}/flows/{flowId}/runs?api-version=2023-06-01
```

## Filtering Flow Runs
Add `$filter` query parameter:

**Filter by time:**
- `$filter=startTime gt 2026-01-09T10:00:00Z` (UTC format required)

**Filter by status:**
- `$filter=status eq 'Failed'` (Failed, Succeeded, Running, Cancelled)

**Combined filters:**
- `$filter=startTime gt 2026-01-09T10:00:00Z and status eq 'Failed'`

## Other Useful Parameters
- `$top=50` - Limit results
- `$skip=100` - Skip first N results
- `$orderby=startTime desc` - Sort by start time

## Response Format
All responses include:
- `value` array containing the results
- `nextLink` for pagination (if more results exist)

## Headers Required
```
Authorization: Bearer {token}
Content-Type: application/json
```

## PowerShell Examples

### Get Token
```powershell
$Body = @{    
    Grant_Type    = "client_credentials"
    Scope = "https://service.powerapps.com/.default"
    client_Id     = $AppId
    Client_Secret = $ClientSecret
} 
$TokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $Body
$Token = $TokenResponse.access_token
```

### Get All Flows in Environment
```powershell
$headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type" = "application/json"
}

$uri = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvironmentId/v2/flows?api-version=2016-11-01"
$response = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing
$flows = ($response.Content | ConvertFrom-Json).value
```

### Get Flow Runs with Filtering
```powershell
# Get failed runs from past 10 minutes
$timeThreshold = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$filter = "`$filter=startTime gt $timeThreshold and status eq 'Failed'"
$uri = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvironmentId/flows/$FlowId/runs?api-version=2023-06-01&$filter"

$response = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing
$flowRuns = ($response.Content | ConvertFrom-Json).value
```

### Handle Pagination
```powershell
$allResults = @()
$currentUri = $initialUri

do {
    $response = Invoke-WebRequest -Uri $currentUri -Headers $headers -Method Get -UseBasicParsing
    $content = $response.Content | ConvertFrom-Json
    
    if ($content.value) {
        $allResults += $content.value
    }
    
    $currentUri = $content.nextLink
} while ($currentUri)
```