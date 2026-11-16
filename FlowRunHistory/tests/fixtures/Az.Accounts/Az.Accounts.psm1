# Synthetic authentication module loaded only by Invoke-Tests.ps1 in its process.
Set-StrictMode -Version Latest

function Get-Fixture {
    if (-not (Get-Variable -Name FlowHistoryAuthFixture -Scope Global -ErrorAction SilentlyContinue)) {
        throw 'This is a test fixture, not an authentication implementation.'
    }
    return $global:FlowHistoryAuthFixture
}

function Connect-AzAccount {
    [CmdletBinding()]
    param([string]$Tenant, [string]$Environment, [string]$Scope,
        [switch]$SkipContextPopulation, [switch]$UseDeviceAuthentication)
    $fixture = Get-Fixture
    $fixture.Calls.Add(@{ Command = 'Connect'; Tenant = $Tenant; Environment = $Environment; Scope = $Scope
        SkipContextPopulation = $SkipContextPopulation.IsPresent; DeviceCode = $UseDeviceAuthentication.IsPresent })
    return [pscustomobject]@{ Context = $fixture.Context }
}

function Get-AzContext {
    [CmdletBinding()]
    param()
    $fixture = Get-Fixture
    $fixture.Calls.Add(@{ Command = 'Context' })
    return $fixture.Context
}

function Get-AzAccessToken {
    [CmdletBinding()]
    param([string]$ResourceUrl, [string]$TenantId, $DefaultProfile)
    $fixture = Get-Fixture
    $fixture.Calls.Add(@{ Command = 'Token'; ResourceUrl = $ResourceUrl; TenantId = $TenantId; Profile = $DefaultProfile })
    return [pscustomobject]@{ Token = $fixture.Token }
}

Export-ModuleMember -Function Connect-AzAccount, Get-AzContext, Get-AzAccessToken
