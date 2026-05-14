<#
.SYNOPSIS
    Reports used vs. available IP addresses in an Azure subnet.

.DESCRIPTION
    Minimal companion to Get-PowerPlatformSubnetIpUsage.ps1. No Dataverse, no
    delegation checks, no per-NIC details - just a friendly summary showing how
    many IPs are in use and how many are still available in the subnet.

    Returns a small [pscustomobject] so you can also consume it programmatically:
        Subnet, AddressPrefixes, UsedIps, AvailableIps, TotalUsableIps, UtilizationPercent

.PARAMETER SubscriptionId
    Azure subscription containing the VNet. Optional; uses current context if omitted.

.PARAMETER ResourceGroupName
    Resource group containing the virtual network.

.PARAMETER VirtualNetworkName
    Name of the virtual network.

.PARAMETER SubnetName
    Name of the subnet.

.PARAMETER Quiet
    Suppress the formatted console output; only emit the result object.

.EXAMPLE
    .\Get-SubnetUsedIpCount.ps1 -ResourceGroupName rg-pp -VirtualNetworkName vnet-pp -SubnetName snet-powerplatform

.EXAMPLE
    # Capture the result object
    $r = .\Get-SubnetUsedIpCount.ps1 -ResourceGroupName rg-pp -VirtualNetworkName vnet-pp -SubnetName snet-pp -Quiet
    if ($r.AvailableIps -lt 5) { Write-Warning "Almost out of IPs!" }
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VirtualNetworkName,
    [Parameter(Mandatory)][string]$SubnetName,
    [switch]$Quiet
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

$reservedIps  = 5  # Azure reserves 5 IPs in every subnet
$usedIps      = @($subnet.IpConfigurations).Count
$totalUsable  = [int]($totalIpsInCidr - $reservedIps)
$availableIps = $totalUsable - $usedIps
$utilPct      = if ($totalUsable -gt 0) { [Math]::Round(($usedIps / $totalUsable) * 100, 2) } else { 0 }

if (-not $Quiet) {
    $availColor = if ($availableIps -le 0)  { 'Red' }
                  elseif ($utilPct -ge 80)  { 'Red' }
                  elseif ($utilPct -ge 60)  { 'Yellow' }
                  else                       { 'Green' }

    $line  = '  +' + ('-' * 56) + '+'
    $title = "  | Subnet IP usage: $SubnetName ($($prefixes -join ', '))"
    $title = $title.PadRight(57) + '|'

    Write-Host ''
    Write-Host $line  -ForegroundColor DarkGray
    Write-Host $title -ForegroundColor Cyan
    Write-Host $line  -ForegroundColor DarkGray
    Write-Host '  | Used        : ' -NoNewline
    Write-Host ('{0,-39}' -f $usedIps) -NoNewline -ForegroundColor White
    Write-Host '|' -ForegroundColor DarkGray
    Write-Host '  | Available   : ' -NoNewline
    $availText = "$availableIps of $totalUsable usable IPs"
    Write-Host ('{0,-39}' -f $availText) -NoNewline -ForegroundColor $availColor
    Write-Host '|' -ForegroundColor DarkGray
    Write-Host '  | Utilization : ' -NoNewline
    Write-Host ('{0,-39}' -f "$utilPct%") -NoNewline -ForegroundColor $availColor
    Write-Host '|' -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkGray
    Write-Host ''
}

[pscustomobject]@{
    Subnet             = $SubnetName
    AddressPrefixes    = ($prefixes -join ', ')
    UsedIps            = $usedIps
    AvailableIps       = $availableIps
    TotalUsableIps     = $totalUsable
    UtilizationPercent = $utilPct
}
