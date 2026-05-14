<#
.SYNOPSIS
    Reports IP address usage for a Power Platform delegated subnet, with optional
    write-back to a Dataverse table for historical tracking.

.DESCRIPTION
    Power Platform VNet support spins up Azure NICs in the delegated subnet (one
    IP per container). There is no native admin report for this yet, so this
    script enumerates the subnet's IP configurations to show real-time usage,
    capacity, and remaining headroom.

    Two collection methods are supported:
      - Az    : Uses Get-AzVirtualNetwork (Az.Network module).
      - Graph : Uses Search-AzGraph against microsoft.network/networkinterfaces
                (Az.ResourceGraph module). Faster for large environments.

    Optional: pass -DataverseUrl, -DataverseClientId, -DataverseClientSecret, and
    -DataverseTenantId (plus -DataverseTableSetName) to push the snapshot into a
    custom Dataverse table for historical reporting. Field names are fully
    customizable via the -DataverseFieldMap hashtable so you can map the script's
    summary fields to your existing column logical names.

.PARAMETER SubscriptionId
    Azure subscription containing the VNet. Optional; uses current context if omitted.

.PARAMETER ResourceGroupName
    Resource group containing the virtual network.

.PARAMETER VirtualNetworkName
    Name of the virtual network.

.PARAMETER SubnetName
    Name of the delegated subnet (delegated to Microsoft.PowerPlatform/enterprisePolicies).

.PARAMETER Method
    'Az' (default) or 'Graph'.

.PARAMETER ShowIpDetails
    Include per-NIC / per-IP rows in the output.

.PARAMETER DataverseUrl
    Dataverse environment URL, e.g. https://orgxxxxxxxx.crm.dynamics.com (no trailing slash required).
    Triggers Dataverse write when supplied.

.PARAMETER DataverseTableSetName
    EntitySetName (plural) of the target Dataverse table, e.g. 'jg_ipusagesnapshots'.
    NOTE: this is the plural collection name, not the LogicalName.

.PARAMETER DataverseTenantId
    Entra tenant GUID used by the app registration that has access to Dataverse.

.PARAMETER DataverseClientId
    Application (client) ID of the Entra app registration used to authenticate to Dataverse.

.PARAMETER DataverseClientSecret
    Client secret value for the app registration. Pass as a SecureString or plain string.

.PARAMETER DataverseFieldMap
    Hashtable mapping script summary field names (keys) to your Dataverse column logical
    names (values). Default mapping uses 'jg_' prefixed names. Example:
      @{
        Timestamp           = 'jg_timestamp'
        Subscription        = 'jg_subscriptionname'
        SubscriptionId      = 'jg_subscriptionid'
        ResourceGroup       = 'jg_resourcegroup'
        VirtualNetwork      = 'jg_virtualnetwork'
        Subnet              = 'jg_subnet'
        AddressPrefixes     = 'jg_addressprefixes'
        DelegatedTo         = 'jg_delegatedto'
        PowerPlatformDelegated = 'jg_powerplatformdelegated'
        TotalIpsInCidr      = 'jg_totalipsincidr'
        AzureReservedIps    = 'jg_azurereservedips'
        UsedIps             = 'jg_usedips'
        AvailableIps        = 'jg_availableips'
        UtilizationPercent  = 'jg_utilizationpercent'
        Method              = 'jg_method'
      }
    Any keys you omit will be skipped during the Dataverse write.

.EXAMPLE
    .\Get-PowerPlatformSubnetIpUsage.ps1 -ResourceGroupName rg-pp -VirtualNetworkName vnet-pp -SubnetName snet-powerplatform

.EXAMPLE
    # Write snapshot to a Dataverse table with custom column names
    .\Get-PowerPlatformSubnetIpUsage.ps1 `
        -ResourceGroupName rg-pp -VirtualNetworkName vnet-pp -SubnetName snet-pp `
        -DataverseUrl 'https://orgxxxx.crm.dynamics.com' `
        -DataverseTenantId '00000000-0000-0000-0000-000000000000' `
        -DataverseClientId '11111111-1111-1111-1111-111111111111' `
        -DataverseClientSecret (Read-Host -AsSecureString 'Client secret') `
        -DataverseTableSetName 'contoso_ppipusagesnapshots' `
        -DataverseFieldMap @{
            Timestamp = 'contoso_capturedat'
            UsedIps   = 'contoso_usedips'
            AvailableIps = 'contoso_availableips'
            Subnet    = 'contoso_subnetname'
        }
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory)]
    [string]$SubnetName,

    [ValidateSet('Az','Graph')]
    [string]$Method = 'Az',

    [switch]$ShowIpDetails,

    # ---- Dataverse (optional) ----
    [string]$DataverseUrl,
    [string]$DataverseTableSetName,
    [string]$DataverseTenantId,
    [string]$DataverseClientId,
    [object]$DataverseClientSecret,   # string or SecureString
    [hashtable]$DataverseFieldMap
)

$ErrorActionPreference = 'Stop'

function Test-Module {
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module '$Name' is not installed. Run: Install-Module $Name -Scope CurrentUser"
    }
}

function ConvertTo-PlainSecret {
    param([Parameter(Mandatory)][object]$Secret)
    if ($Secret -is [securestring]) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } else {
        [string]$Secret
    }
}

function Get-SubnetIpConfiguration {
    <#
    .SYNOPSIS
        Returns the active IP configurations for a subnet using either Az.Network or Resource Graph.
    .OUTPUTS
        [pscustomobject] with NicName, IpAddress, Source. IpAddress is $null for Az unless -IncludeIpAddress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Az','Graph')] [string]$Method,
        [Parameter(Mandatory)] $Subnet,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [switch]$IncludeIpAddress
    )

    switch ($Method) {
        'Az' {
            $items = foreach ($ipc in $Subnet.IpConfigurations) {
                # ipc.Id looks like .../networkInterfaces/<nic>/ipConfigurations/<name>
                $nicName = ($ipc.Id -split '/networkInterfaces/')[1].Split('/')[0]
                [pscustomobject]@{ NicName = $nicName; IpAddress = $null; Source = 'Az' }
            }

            if (-not $IncludeIpAddress -or -not $items) { return $items }

            # Resolve the actual private IPs by reading each NIC
            $nicNames = $items.NicName | Select-Object -Unique
            $nics = foreach ($n in $nicNames) {
                try { Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $n -ErrorAction Stop }
                catch { Write-Verbose "Could not read NIC $n - $($_.Exception.Message)"; $null }
            }
            return @(
                foreach ($nic in $nics | Where-Object { $_ }) {
                    foreach ($cfg in $nic.IpConfigurations) {
                        if ($cfg.Subnet.Id -eq $Subnet.Id) {
                            [pscustomobject]@{
                                NicName   = $nic.Name
                                IpAddress = $cfg.PrivateIpAddress
                                Source    = 'Az'
                            }
                        }
                    }
                }
            )
        }

        'Graph' {
            Test-Module -Name 'Az.ResourceGraph'
            $targetSubnetId = $Subnet.Id
            $kql = @"
resources
| where type == 'microsoft.network/networkinterfaces'
| mv-expand ipConfig = properties.ipConfigurations
| where tolower(tostring(ipConfig.properties.subnet.id)) == tolower('$targetSubnetId')
| project nicName = name, ipAddress = tostring(ipConfig.properties.privateIPAddress)
"@
            $rows = Search-AzGraph -Query $kql -Subscription $SubscriptionId -First 1000
            return @(
                foreach ($r in $rows) {
                    [pscustomobject]@{ NicName = $r.nicName; IpAddress = $r.ipAddress; Source = 'Graph' }
                }
            )
        }
    }
}

function Write-DataverseSnapshot {
    <#
    .SYNOPSIS
        POSTs a snapshot object to a Dataverse table using OAuth2 client_credentials.
    .OUTPUTS
        [pscustomobject] with TableSetName, RecordId, StatusCode, Url.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataverseUrl,
        [Parameter(Mandatory)][string]$TableSetName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][object]$ClientSecret,
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)][hashtable]$FieldMap
    )

    $dvBase   = $DataverseUrl.TrimEnd('/')
    $secret   = ConvertTo-PlainSecret -Secret $ClientSecret
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    Write-Verbose "Acquiring Dataverse OAuth token from $tokenUrl"
    try {
        $tokenResp = Invoke-WebRequest -Uri $tokenUrl -Method POST -UseBasicParsing -ErrorAction Stop `
            -ContentType 'application/x-www-form-urlencoded' -Body @{
                client_id     = $ClientId
                client_secret = $secret
                scope         = "$dvBase/.default"
                grant_type    = 'client_credentials'
            }
        $token = ($tokenResp.Content | ConvertFrom-Json).access_token
    } catch {
        throw "Failed to acquire Dataverse token: $($_.Exception.Message)"
    }

    # Build payload using only the mapped fields that exist on the snapshot
    $payload = [ordered]@{}
    foreach ($key in $FieldMap.Keys) {
        if ($null -ne $FieldMap[$key] -and $null -ne $Snapshot.PSObject.Properties[$key]) {
            $payload[$FieldMap[$key]] = $Snapshot.$key
        }
    }
    # Provide a sensible primary-name value if the map includes it
    if ($FieldMap.ContainsKey('Name') -and $FieldMap['Name']) {
        $payload[$FieldMap['Name']] = "$($Snapshot.Subnet) @ $($Snapshot.Timestamp)"
    }

    $createUri = "$dvBase/api/data/v9.2/$TableSetName"
    $headers = @{
        Authorization      = "Bearer $token"
        'OData-Version'    = '4.0'
        'OData-MaxVersion' = '4.0'
        Accept             = 'application/json'
        Prefer             = 'return=representation'
    }
    $json = $payload | ConvertTo-Json -Depth 5

    Write-Verbose "POST $createUri"
    Write-Verbose $json
    try {
        $resp = Invoke-WebRequest -Uri $createUri -Method POST -Headers $headers `
            -Body $json -ContentType 'application/json; charset=utf-8' -UseBasicParsing -ErrorAction Stop
        $created = $resp.Content | ConvertFrom-Json
        $recordId = $created."$($TableSetName.TrimEnd('s'))id"
        if (-not $recordId) {
            $loc = $resp.Headers['OData-EntityId']
            if ($loc -and $loc -match '\(([0-9a-fA-F-]{36})\)') { $recordId = $matches[1] }
        }
        return [pscustomobject]@{
            TableSetName = $TableSetName
            RecordId     = $recordId
            StatusCode   = [int]$resp.StatusCode
            Url          = $createUri
        }
    } catch {
        $errBody = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $errBody = $_.ErrorDetails.Message }
        elseif ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errBody = $reader.ReadToEnd()
            } catch {}
        }
        throw "Dataverse write failed: $($_.Exception.Message)`nResponse: $errBody"
    }
}

# Ensure context
Test-Module -Name 'Az.Accounts'
$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host "No Az context found. Launching Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
    $ctx = Get-AzContext
}

if ($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId) {
    Write-Verbose "Switching subscription to $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $ctx = Get-AzContext
}

# Get subnet (always via Az.Network so we can read AddressPrefix + delegations)
Test-Module -Name 'Az.Network'
$vnet   = Get-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $ResourceGroupName
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName

# Address space (subnet may have one or multiple prefixes)
$prefixes = @()
if ($subnet.AddressPrefix)   { $prefixes += $subnet.AddressPrefix }
if ($subnet.AddressPrefixes) { $prefixes += $subnet.AddressPrefixes }
$prefixes = $prefixes | Select-Object -Unique

$totalIpsInCidr = 0
foreach ($p in $prefixes) {
    $cidr = [int]$p.Split('/')[1]
    $totalIpsInCidr += [Math]::Pow(2, 32 - $cidr)
}

# Delegation info
$delegations = @($subnet.Delegations | ForEach-Object { $_.ServiceName })
$isPpDelegated = $delegations -contains 'Microsoft.PowerPlatform/enterprisePolicies'

# Collect used IPs
$ipDetails = @(Get-SubnetIpConfiguration -Method $Method -Subnet $subnet `
    -ResourceGroupName $ResourceGroupName -SubscriptionId $ctx.Subscription.Id `
    -IncludeIpAddress:$ShowIpDetails)

$usedIps     = $ipDetails.Count
$reservedIps = 5  # Azure reserves 5 IPs in every subnet
$availableIps = $totalIpsInCidr - $reservedIps - $usedIps

$summary = [pscustomobject]@{
    Timestamp           = (Get-Date).ToString('s')
    Subscription        = $ctx.Subscription.Name
    SubscriptionId      = $ctx.Subscription.Id
    ResourceGroup       = $ResourceGroupName
    VirtualNetwork      = $VirtualNetworkName
    Subnet              = $SubnetName
    AddressPrefixes     = ($prefixes -join ', ')
    DelegatedTo         = (($delegations -join ', '))
    PowerPlatformDelegated = $isPpDelegated
    TotalIpsInCidr      = [int]$totalIpsInCidr
    AzureReservedIps    = $reservedIps
    UsedIps             = $usedIps
    AvailableIps        = [int]$availableIps
    UtilizationPercent  = if ($totalIpsInCidr -gt 0) {
        [Math]::Round(($usedIps / ($totalIpsInCidr - $reservedIps)) * 100, 2)
    } else { 0 }
    Method              = $Method
}

Write-Host ""
Write-Host "Power Platform Delegated Subnet IP Usage" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
$summary | Format-List

if (-not $isPpDelegated) {
    Write-Warning "Subnet is not delegated to Microsoft.PowerPlatform/enterprisePolicies. Counts still valid, but this may not be a Power Platform subnet."
}

if ($ShowIpDetails -and $ipDetails.Count -gt 0) {
    Write-Host "Active IP Configurations:" -ForegroundColor Cyan
    $ipDetails | Sort-Object IpAddress | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# Optional: write the snapshot to a Dataverse table
# ---------------------------------------------------------------------------
$dataverseResult = $null
if ($DataverseUrl) {
    $missing = @()
    foreach ($p in 'DataverseTableSetName','DataverseTenantId','DataverseClientId','DataverseClientSecret') {
        if (-not $PSBoundParameters.ContainsKey($p) -or [string]::IsNullOrWhiteSpace([string]$PSBoundParameters[$p])) {
            $missing += $p
        }
    }
    if ($missing.Count) {
        throw "DataverseUrl supplied but missing required parameter(s): $($missing -join ', ')"
    }

    # Default field map (keys = summary property; values = Dataverse column logical name)
    $defaultMap = @{
        Timestamp              = 'jg_timestamp'
        Subscription           = 'jg_subscriptionname'
        SubscriptionId         = 'jg_subscriptionid'
        ResourceGroup          = 'jg_resourcegroup'
        VirtualNetwork         = 'jg_virtualnetwork'
        Subnet                 = 'jg_subnet'
        AddressPrefixes        = 'jg_addressprefixes'
        DelegatedTo            = 'jg_delegatedto'
        PowerPlatformDelegated = 'jg_powerplatformdelegated'
        TotalIpsInCidr         = 'jg_totalipsincidr'
        AzureReservedIps       = 'jg_azurereservedips'
        UsedIps                = 'jg_usedips'
        AvailableIps           = 'jg_availableips'
        UtilizationPercent     = 'jg_utilizationpercent'
        Method                 = 'jg_method'
    }
    $fieldMap = if ($DataverseFieldMap) { $DataverseFieldMap } else { $defaultMap }

    $dataverseResult = Write-DataverseSnapshot `
        -DataverseUrl  $DataverseUrl `
        -TableSetName  $DataverseTableSetName `
        -TenantId      $DataverseTenantId `
        -ClientId      $DataverseClientId `
        -ClientSecret  $DataverseClientSecret `
        -Snapshot      $summary `
        -FieldMap      $fieldMap

    Write-Host "Wrote snapshot to Dataverse table '$DataverseTableSetName' (id: $($dataverseResult.RecordId))" -ForegroundColor Green
}

# Emit objects to the pipeline for downstream use (e.g., piping into Log Analytics)
[pscustomobject]@{
    Summary   = $summary
    Details   = $ipDetails
    Dataverse = $dataverseResult
}
