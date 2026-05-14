# Power Platform Subnet IP Usage

PowerShell script that reports IP-address utilization for the Azure subnet you have delegated to **Microsoft.PowerPlatform/enterprisePolicies** (Power Platform VNet support / "VNet integration"), and optionally writes a snapshot to a Dataverse table for historical tracking.

When you enable Power Platform VNet support, every Power Platform container that runs against the policy consumes one IP from the delegated subnet. There is no native Maker/Admin Portal report for "how many IPs are still available", so this script fills the gap.

## What it does

- Enumerates the IP configurations attached to the delegated subnet.
- Reports total / used / available IPs and a utilization percentage.
- Confirms whether the subnet is actually delegated to `Microsoft.PowerPlatform/enterprisePolicies`.
- Supports two collection methods:
  - **Az** – `Get-AzVirtualNetwork` (Az.Network). Default. Best for one-off checks.
  - **Graph** – `Search-AzGraph` against `microsoft.network/networkinterfaces` (Az.ResourceGraph). Faster across large estates.
- Optionally POSTs the snapshot to a Dataverse custom table via the Web API (`Invoke-WebRequest`) using OAuth2 client-credentials.

## Prerequisites

### 1. PowerShell 7+ (recommended)

The script targets PowerShell 7+, but Windows PowerShell 5.1 also works.

Check your version:

```powershell
$PSVersionTable.PSVersion
```

Install PowerShell 7 if needed:

```powershell
winget install --id Microsoft.PowerShell
```

### 2. Azure PowerShell modules

The script always needs `Az.Accounts` and `Az.Network`. `Az.ResourceGraph` is only needed if you use `-Method Graph`.

```powershell
Install-Module Az.Accounts, Az.Network -Scope CurrentUser -Force
# Optional - only for -Method Graph
Install-Module Az.ResourceGraph -Scope CurrentUser -Force
```

Verify they installed:

```powershell
Get-Module -ListAvailable Az.Accounts, Az.Network, Az.ResourceGraph |
    Select-Object Name, Version
```

### 3. Authenticated Azure session

The signed-in identity needs at minimum **Reader** on the resource group containing the VNet.

```powershell
Connect-AzAccount -TenantId <tenant-guid>
Set-AzContext -SubscriptionId <subscription-guid>
```

If you do not have Reader yet, an Owner / User Access Administrator can grant it with:

```powershell
New-AzRoleAssignment -SignInName 'you@contoso.com' `
    -RoleDefinitionName 'Reader' `
    -ResourceGroupName 'rg-platform-network'
```

### 4. (Optional) Dataverse environment, app registration, table, and Application User

You only need this if you want the historical-tracking write-back. See [Dataverse setup](#dataverse-setup-optional) below for the full walkthrough.

## Quick start

```powershell
.\Get-PowerPlatformSubnetIpUsage.ps1 `
  -ResourceGroupName  'rg-platform-network' `
  -VirtualNetworkName 'vnet-platform-eastus' `
  -SubnetName         'snet-powerplatform'
```

Sample output (`Summary` object):

```
Timestamp              : 2026-01-15T18:40:25Z
Subscription           : Contoso-Prod
SubscriptionId         : 00000000-0000-0000-0000-000000000000
ResourceGroup          : rg-platform-network
VirtualNetwork         : vnet-platform-eastus
Subnet                 : snet-powerplatform
AddressPrefixes        : 10.50.0.32/27
DelegatedTo            : Microsoft.PowerPlatform/enterprisePolicies
PowerPlatformDelegated : True
TotalIpsInCidr         : 32
AzureReservedIps       : 5
UsedIps                : 12
AvailableIps           : 15
UtilizationPercent     : 44.44
Method                 : Az
```

> **Why `AzureReservedIps = 5`?** Azure reserves the network address, broadcast address, the default gateway, and two addresses for Azure DNS in every subnet. The script subtracts these so `UsedIps + AvailableIps = TotalIpsInCidr - 5`.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `SubscriptionId` | No | Azure subscription containing the VNet. Uses current `Get-AzContext` if omitted. |
| `ResourceGroupName` | **Yes** | Resource group of the virtual network. |
| `VirtualNetworkName` | **Yes** | Name of the VNet. |
| `SubnetName` | **Yes** | Name of the delegated subnet. |
| `Method` | No | `Az` (default) or `Graph`. |
| `ShowIpDetails` | No | Switch. Adds the per-NIC `Details` collection to the output. |
| `DataverseUrl` | No | Dataverse environment URL, e.g. `https://orgxxxxxxxx.crm.dynamics.com`. Triggers Dataverse write when supplied. |
| `DataverseTableSetName` | No | EntitySetName (plural) of the target table, e.g. `jg_ipusagesnapshots`. |
| `DataverseTenantId` | No | Entra tenant GUID. |
| `DataverseClientId` | No | Application (client) ID of the app registration. |
| `DataverseClientSecret` | No | Client secret value. Accepts a `SecureString` or plain string. |
| `DataverseFieldMap` | No | Hashtable mapping logical script field names to your Dataverse column logical names. See [Customizing field names](#customizing-field-names). |

## Examples

### 1. Basic Az-based report

```powershell
.\Get-PowerPlatformSubnetIpUsage.ps1 `
  -ResourceGroupName  'rg-platform-network' `
  -VirtualNetworkName 'vnet-platform-eastus' `
  -SubnetName         'snet-powerplatform'
```

### 2. Show the per-NIC details

```powershell
$result = .\Get-PowerPlatformSubnetIpUsage.ps1 `
  -ResourceGroupName  'rg-platform-network' `
  -VirtualNetworkName 'vnet-platform-eastus' `
  -SubnetName         'snet-powerplatform' `
  -ShowIpDetails

$result.Details | Format-Table NicName, IpAddress, Source
```

### 3. Faster report across a large environment via Resource Graph

```powershell
.\Get-PowerPlatformSubnetIpUsage.ps1 `
  -ResourceGroupName  'rg-platform-network' `
  -VirtualNetworkName 'vnet-platform-eastus' `
  -SubnetName         'snet-powerplatform' `
  -Method Graph
```

### 4. Run against an explicit subscription (no need to switch context first)

```powershell
.\Get-PowerPlatformSubnetIpUsage.ps1 `
  -SubscriptionId     '00000000-0000-0000-0000-000000000000' `
  -ResourceGroupName  'rg-platform-network' `
  -VirtualNetworkName 'vnet-platform-eastus' `
  -SubnetName         'snet-powerplatform'
```

### 5. Loop over every Power Platform delegated subnet in the subscription

Useful when you have several VNets / regions and want a single report.

```powershell
$rows = Search-AzGraph -Query @"
resources
| where type == 'microsoft.network/virtualnetworks'
| mv-expand subnet = properties.subnets
| mv-expand delegation = subnet.properties.delegations
| where tostring(delegation.properties.serviceName) == 'Microsoft.PowerPlatform/enterprisePolicies'
| project rg = resourceGroup, vnet = name, subnet = tostring(subnet.name)
"@

$report = foreach ($r in $rows) {
    (& .\Get-PowerPlatformSubnetIpUsage.ps1 `
        -ResourceGroupName  $r.rg `
        -VirtualNetworkName $r.vnet `
        -SubnetName         $r.subnet `
        -Method Graph).Summary
}

$report | Format-Table Subnet, TotalIpsInCidr, UsedIps, AvailableIps, UtilizationPercent
$report | Export-Csv .\pp-subnet-usage.csv -NoTypeInformation
```

### 6. Alert when utilization crosses a threshold

```powershell
$threshold = 80
$summary = (& .\Get-PowerPlatformSubnetIpUsage.ps1 `
    -ResourceGroupName  'rg-platform-network' `
    -VirtualNetworkName 'vnet-platform-eastus' `
    -SubnetName         'snet-powerplatform').Summary

if ($summary.UtilizationPercent -ge $threshold) {
    Send-MailMessage -To 'platform-ops@contoso.com' `
        -From 'azure-bot@contoso.com' `
        -Subject "Power Platform subnet at $($summary.UtilizationPercent)%" `
        -Body ($summary | Format-List | Out-String) `
        -SmtpServer 'smtp.contoso.com'
}
```

### 7. Run as a scheduled snapshot and write to Dataverse

Store your Dataverse client secret in an environment variable (or pull it from Key Vault) so it never appears on disk:

```powershell
$secret = ConvertTo-SecureString $env:DV_CLIENT_SECRET -AsPlainText -Force

.\Get-PowerPlatformSubnetIpUsage.ps1 `
  -ResourceGroupName     'rg-platform-network' `
  -VirtualNetworkName    'vnet-platform-eastus' `
  -SubnetName            'snet-powerplatform' `
  -DataverseUrl          'https://orgxxxxxxxx.crm.dynamics.com' `
  -DataverseTableSetName 'jg_ipusagesnapshots' `
  -DataverseTenantId     '00000000-0000-0000-0000-000000000000' `
  -DataverseClientId     '11111111-1111-1111-1111-111111111111' `
  -DataverseClientSecret $secret
```

The script returns:

```text
Summary    : <pscustomobject with the aggregate snapshot>
Details    : <per-NIC rows when -ShowIpDetails is set>
Dataverse  : @{ TableSetName; RecordId; StatusCode; Url }
```

### 8. Pull the Dataverse secret from Azure Key Vault

```powershell
$secret = (Get-AzKeyVaultSecret -VaultName 'kv-platform' -Name 'dv-clientsecret').SecretValue

.\Get-PowerPlatformSubnetIpUsage.ps1 `
  -ResourceGroupName     'rg-platform-network' `
  -VirtualNetworkName    'vnet-platform-eastus' `
  -SubnetName            'snet-powerplatform' `
  -DataverseUrl          'https://orgxxxxxxxx.crm.dynamics.com' `
  -DataverseTableSetName 'jg_ipusagesnapshots' `
  -DataverseTenantId     '00000000-0000-0000-0000-000000000000' `
  -DataverseClientId     '11111111-1111-1111-1111-111111111111' `
  -DataverseClientSecret $secret
```

## Dataverse setup (optional)

You only need this if you want the historical-tracking write-back. Skip the section if you just want point-in-time reports.

### 1. Create an Entra app registration

1. **Entra ID → App registrations → New registration.** Single tenant is fine.
2. Generate a **client secret** and copy the value (you will only see it once).
3. No Graph or Dynamics CRM API permissions are required for the script — Dataverse is gated by the Application User you create in step 3, not by API permissions.

### 2. Create the target Dataverse table

In your Dataverse environment, create a custom table (the script defaults assume the table logical name `jg_ipusagesnapshot` and EntitySetName `jg_ipusagesnapshots`, but you can change either).

Recommended columns (logical names match the script's default `DataverseFieldMap`):

| Display name | Logical name | Type | Notes |
|---|---|---|---|
| Name | `jg_name` | Text (200) | Primary name column. |
| Timestamp | `jg_timestamp` | Date & Time | UTC timestamp of the snapshot. |
| Subscription | `jg_subscriptionname` | Text (200) | |
| Subscription Id | `jg_subscriptionid` | Text (200) | |
| Resource Group | `jg_resourcegroup` | Text (200) | |
| Virtual Network | `jg_virtualnetwork` | Text (200) | |
| Subnet | `jg_subnet` | Text (200) | |
| Address Prefixes | `jg_addressprefixes` | Text (200) | Comma-joined when more than one. |
| Delegated To | `jg_delegatedto` | Text (500) | |
| Power Platform Delegated | `jg_powerplatformdelegated` | Yes/No | |
| Total IPs In CIDR | `jg_totalipsincidr` | Whole Number | |
| Azure Reserved IPs | `jg_azurereservedips` | Whole Number | Always 5 today. |
| Used IPs | `jg_usedips` | Whole Number | |
| Available IPs | `jg_availableips` | Whole Number | |
| Utilization Percent | `jg_utilizationpercent` | Decimal (precision 2) | |
| Method | `jg_method` | Text (50) | `Az` or `Graph`. |

### 3. Add the app registration as an Application User

1. **Power Platform Admin Center → Environments → *(your env)* → Settings → Users + permissions → Application users.**
2. **+ New app user.** Pick the Entra app from step 1. Assign a security role that can **create** rows in your custom table (a custom role with table `jg_ipusagesnapshot` Create / Read / Append / Append To privileges is the cleanest answer; **System Customizer** also works for testing).

### 4. Run the script with the Dataverse parameters

See [Example 7](#7-run-as-a-scheduled-snapshot-and-write-to-dataverse).

### 5. Customizing field names

There are two ways to change the column logical names the script writes to:

#### Option A — pass `-DataverseFieldMap` per invocation (no script changes)

Best when you only need to override a few columns or when different environments use different schemas. Any key you omit still uses the in-script default; any key you set to `$null` is **skipped** during the write.

```powershell
$map = @{
  Timestamp           = 'contoso_snapshotat'
  UsedIps             = 'contoso_usedips'
  AvailableIps        = 'contoso_availableips'
  UtilizationPercent  = 'contoso_utilization'
  # other fields keep their defaults
}

.\Get-PowerPlatformSubnetIpUsage.ps1 ... -DataverseFieldMap $map
```

#### Option B — edit the in-script default map (permanent change)

Best when your whole organization uses a single non-`jg_` prefix and you do not want to pass `-DataverseFieldMap` every time. Open `Get-PowerPlatformSubnetIpUsage.ps1`, find the `$defaultMap` hashtable inside the `if ($DataverseUrl)` block (search for `$defaultMap = @{`), and edit the values on the right-hand side. The keys on the left **must not change** — they are the script's internal property names — only the values (your Dataverse column logical names) should be edited.

```powershell
# Before
$defaultMap = @{
    Timestamp              = 'jg_timestamp'
    Subscription           = 'jg_subscriptionname'
    ...
    Method                 = 'jg_method'
}

# After (Contoso prefix)
$defaultMap = @{
    Timestamp              = 'contoso_timestamp'
    Subscription           = 'contoso_subscriptionname'
    ...
    Method                 = 'contoso_method'
}
```

You can also remove rows from the map entirely if your table does not have those columns — the script skips any key whose Dataverse column is not present.

If you change the table's logical name as well, also update the `-DataverseTableSetName` value you pass at the command line (or set a default for the parameter at the top of the script).

## Suggested historical-tracking patterns

- **Azure Automation runbook** (PowerShell 7.2 runtime) on a schedule — easiest path. Use a system-assigned managed identity with Reader on the VNet for Azure auth, and the app registration / secret stored in an Automation credential for Dataverse.
- **GitHub Actions / Azure DevOps pipeline** on a `schedule:` trigger — same idea, secrets live in your CI store.
- **Power BI on the Dataverse table** — line chart of `UtilizationPercent` over `Timestamp` per `Subnet` is a one-pager that shows growth and headroom.

## Troubleshooting

- **`Get-AzVirtualNetwork` returns nothing / `ResourceNotFound`.** You are connected to the wrong subscription. Run `Set-AzContext -SubscriptionId <id>` or pass `-SubscriptionId`.
- **Dataverse write returns 401.** The app registration is not added as an Application User in that environment, or the security role lacks Create rights.
- **Dataverse write returns 403.** Same as 401, check the security role.
- **Dataverse write returns 404 on POST.** `DataverseTableSetName` is wrong — it must be the **EntitySetName** (typically the plural of the table logical name), not the table logical name itself. Check it in `<env>/api/data/v9.2/EntityDefinitions(LogicalName='your_table')?$select=EntitySetName`.
- **Output shows `PowerPlatformDelegated: False`.** The subnet exists but is not delegated to `Microsoft.PowerPlatform/enterprisePolicies`; the script still reports IP usage but you are not actually measuring Power Platform consumption.

## License & disclaimer

Copyright 2026 Jake Gwynn

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
