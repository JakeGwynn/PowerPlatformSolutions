# Environment IDs to monitor - add your environment IDs here
$EnvironmentIds = @(
    "c06739f2-2f57-eff1-9d90-e8907bb6701c",
	"9c99f036-8d9d-e447-be8c-2b75f3a29f10"
)

# Dataverse configuration
$DataverseUrl = "https://orgb9d46ed6.crm.dynamics.com/"  # Replace with your Dataverse URL
$Prefix = "cre8f_"  # Replace with your custom prefix (include underscore if needed)
$DataverseTableName = "flowrunfailure"  # Base table name without prefix

$ClientSecret = ""
$TenantId = ""
$AppId = ""

[System.Net.ServicePointManager]::SecurityProtocol = 'TLS12'

$TokenTimer = $null
$Token = $null
$DataverseToken = $null

function Get-RestApiError ($RestError) {
    if ($RestError.Exception.GetType().FullName -eq "System.Net.WebException") {
        $ResponseStream = $null
        $Reader = $null
        $ResponseStream = $RestError.Exception.Response.GetResponseStream()
        $Reader = New-Object System.IO.StreamReader($ResponseStream)
        $Reader.BaseStream.Position = 0
        $Reader.DiscardBufferedData()
        return $Reader.ReadToEnd();
    }
}

function Get-MSToken ($TenantId, $AppId, $ClientSecret, $Scope = "https://service.powerapps.com/.default") {
    try{
        Write-Host "Authenticating to $Scope"
        $Body = @{    
            Grant_Type    = "client_credentials"
            Scope = $Scope
            client_Id     = $AppId
            Client_Secret = $ClientSecret
            } 
        $ConnectGraph = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $Body
        $global:TokenTimer = [system.diagnostics.stopwatch]::StartNew()	
        return $ConnectGraph.access_token
    }
    catch {
        $RestError = $null
        $RestError = Get-RestApiError -RestError $_
        Write-Host $_ -ForegroundColor Red
        return Write-Host $RestError -ForegroundColor Red 
    }
}

function Get-AllPagesFromApi ($InitialUri, $Headers) {
    $allResults = @()
    $currentUri = $InitialUri
    
    do {
        try {
            $response = Invoke-WebRequest -Uri $currentUri -Headers $Headers -Method Get -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            
            if ($content.value) {
                $allResults += $content.value
            }
            
            $currentUri = $content.nextLink
        }
        catch {
            Write-Host "Error in pagination: $_" -ForegroundColor Red
            break
        }
    } while ($currentUri)
    
    return $allResults
}

function Check-FlowRunInDataverse ($FlowRunId, $DataverseHeaders) {
    try {
        $fullTableName = "${Prefix}${DataverseTableName}"
        $flowRunIdColumn = "${Prefix}flowrunid"
        $filterQuery = "`$filter=$flowRunIdColumn eq '$FlowRunId'"
        $uri = "$DataverseUrl/api/data/v9.2/${fullTableName}s?$filterQuery"
        $response = Invoke-WebRequest -Uri $uri -Headers $DataverseHeaders -Method Get -UseBasicParsing
        $content = $response.Content | ConvertFrom-Json
        return $content.value.Count -gt 0
    }
    catch {
        Write-Host "Error checking Dataverse: $_" -ForegroundColor Red
        return $false
    }
}

function Add-FlowRunToDataverse ($FlowRun, $DataverseHeaders) {
    try {
        $fullTableName = "${Prefix}${DataverseTableName}"
        $body = @{}
        $body["${Prefix}flowrunid"] = $FlowRun.name
        $body["${Prefix}starttime"] = $FlowRun.properties.startTime
        $body["${Prefix}endtime"] = $FlowRun.properties.endTime
        $body["${Prefix}runstatus"] = $FlowRun.properties.status
        $body["${Prefix}isaborted"] = $FlowRun.properties.isAborted
        
        $jsonBody = $body | ConvertTo-Json

        $uri = "$DataverseUrl/api/data/v9.2/${fullTableName}s"
        $response = Invoke-WebRequest -Uri $uri -Headers $DataverseHeaders -Method Post -Body $jsonBody -UseBasicParsing
        Write-Host "Added flow run failure record: $($FlowRun.name)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error adding to Dataverse: $_" -ForegroundColor Red
        $RestError = Get-RestApiError -RestError $_
        Write-Host $RestError -ForegroundColor Red
        return $false
    }
}

# Get tokens for Power Platform and Dataverse
Write-Host "Getting Power Platform token..." -ForegroundColor Yellow
$Token = Get-MSToken -TenantId $TenantId -AppId $AppId -ClientSecret $ClientSecret

Write-Host "Getting Dataverse token..." -ForegroundColor Yellow
$DataverseToken = Get-MSToken -TenantId $TenantId -AppId $AppId -ClientSecret $ClientSecret -Scope "$DataverseUrl/.default"

$headers = @{
    "Authorization" = "Bearer $Token"
    "Content-type" = "application/json"
}

$DataverseHeaders = @{
    "Authorization" = "Bearer $DataverseToken"
    "Content-Type" = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version" = "4.0"
}

# Calculate time threshold (10 minutes ago) - all UTC
$TimeThreshold = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "Monitoring for failures since: $TimeThreshold (UTC)" -ForegroundColor Yellow

$TotalFailuresProcessed = 0
$NewFailuresAdded = 0

# Process each environment
foreach ($EnvironmentId in $EnvironmentIds) {
    Write-Host "`nProcessing Environment: $EnvironmentId" -ForegroundColor Cyan
    
    try {
        # Get all flows in the environment with pagination
        $flowsUri = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvironmentId/v2/flows?api-version=2016-11-01"
        $allFlows = Get-AllPagesFromApi -InitialUri $flowsUri -Headers $headers
        
        Write-Host "Found $($allFlows.Count) flows in environment" -ForegroundColor Green
        
        # Sort flows alphabetically by display name
        $sortedFlows = $allFlows | Sort-Object { $_.properties.displayName }
        
        # Process each flow
        foreach ($flow in $sortedFlows) {
            Write-Host "  Checking flow: $($flow.properties.displayName) ($($flow.name))" -ForegroundColor Gray
            
            try {
                # Get flow runs for this flow with pagination - filter using UTC time
                $runsUri = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvironmentId/flows/$($flow.name)/runs?api-version=2023-06-01&`$filter=startTime gt $TimeThreshold"
                $allFlowRuns = Get-AllPagesFromApi -InitialUri $runsUri -Headers $headers
                
                # Debug: Show all runs found by API
                Write-Host "    API returned $($allFlowRuns.Count) runs total" -ForegroundColor Gray
                if ($allFlowRuns.Count -gt 0) {
                    Write-Host "    Sample run times and statuses:" -ForegroundColor Gray
                    $allFlowRuns | Select-Object -First 3 | ForEach-Object {
                        Write-Host "      $($_.properties.startTime) - $($_.properties.status)" -ForegroundColor Gray
                    }
                }
                
                # Calculate status statistics
                if ($allFlowRuns.Count -gt 0) {
                    $statusStats = $allFlowRuns | Group-Object { $_.properties.status } | ForEach-Object { "$($_.Name): $($_.Count)" }
                    Write-Host "    Total runs in time window: $($allFlowRuns.Count) ($($statusStats -join ', '))" -ForegroundColor Cyan
                } else {
                    Write-Host "    Total runs in time window: 0" -ForegroundColor Cyan
                }
                
                # Filter for failures
                $recentFailures = $allFlowRuns | Where-Object { $_.properties.status -eq "Failed" }
                
                if ($recentFailures.Count -gt 0) {
                    Write-Host "    Found $($recentFailures.Count) recent failures" -ForegroundColor Yellow
                    
                    foreach ($failure in $recentFailures) {
                        $TotalFailuresProcessed++
                        Write-Host "      Processing failure: $($failure.name)" -ForegroundColor Yellow
                        
                        # Check if this failure already exists in Dataverse
                        $existsInDataverse = Check-FlowRunInDataverse -FlowRunId $failure.name -DataverseHeaders $DataverseHeaders
                        
                        if (-not $existsInDataverse) {
                            # Add to Dataverse
                            $added = Add-FlowRunToDataverse -FlowRun $failure -DataverseHeaders $DataverseHeaders
                            if ($added) {
                                $NewFailuresAdded++
                            }
                        } else {
                            Write-Host "      Flow run already exists in Dataverse: $($failure.name)" -ForegroundColor Gray
                        }
                    }
                }
            }
            catch {
                Write-Host "    Error getting runs for flow $($flow.name): $_" -ForegroundColor Red
                continue
            }
        }
    }
    catch {
        Write-Host "Error processing environment $EnvironmentId : $_" -ForegroundColor Red
        $RestError = Get-RestApiError -RestError $_
        Write-Host $RestError -ForegroundColor Red
        continue
    }
}

# Summary
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Environments processed: $($EnvironmentIds.Count)" -ForegroundColor Green
Write-Host "Total failures found in past 10 minutes: $TotalFailuresProcessed" -ForegroundColor Yellow
Write-Host "New failure records added to Dataverse: $NewFailuresAdded" -ForegroundColor Green
Write-Host "Script completed at: $(Get-Date)" -ForegroundColor Green