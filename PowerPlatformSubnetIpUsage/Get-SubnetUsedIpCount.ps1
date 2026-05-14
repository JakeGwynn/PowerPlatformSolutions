<#
.SYNOPSIS
    Returns the number of used IP addresses in an Azure subnet.

.DESCRIPTION
    Minimal companion to Get-PowerPlatformSubnetIpUsage.ps1. No Dataverse, no
    delegation checks, no per-NIC details, no utilization math - just a single
    integer count of IP configurations attached to the subnet.

    Useful for: quick CLI checks, embedding in other scripts via
    `(.\Get-SubnetUsedIpCount.ps1 ...)`, dashboards that only need the raw count.

.PARAMETER SubscriptionId
    Azure subscription containing the VNet. Optional; uses current context if omitted.

.PARAMETER ResourceGroupName
    Resource group containing the virtual network.

.PARAMETER VirtualNetworkName
    Name of the virtual network.

.PARAMETER SubnetName
    Name of the subnet.

.EXAMPLE
    .\Get-SubnetUsedIpCount.ps1 -ResourceGroupName rg-pp -VirtualNetworkName vnet-pp -SubnetName snet-powerplatform
    12

.EXAMPLE
    # Use the value in a comparison
    if ((.\Get-SubnetUsedIpCount.ps1 -ResourceGroupName rg-pp -VirtualNetworkName vnet-pp -SubnetName snet-pp) -gt 50) {
        Write-Warning "Subnet usage is climbing"
    }
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VirtualNetworkName,
    [Parameter(Mandatory)][string]$SubnetName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Az.Network)) {
    throw "Az.Network module is required. Install with: Install-Module Az.Network -Scope CurrentUser"
}

$ctx = Get-AzContext
if (-not $ctx) {
    Connect-AzAccount | Out-Null
}
if ($SubscriptionId -and (Get-AzContext).Subscription.Id -ne $SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$vnet   = Get-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $ResourceGroupName
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName

@($subnet.IpConfigurations).Count
