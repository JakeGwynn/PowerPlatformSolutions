#Requires -Version 5.1

<#
.SYNOPSIS
Inventories premium-capability apps in unmanaged Developer environments, tenant-wide.

.DESCRIPTION
Read-only, commercial-cloud inventory using delegated user authentication. Discovers
all app types through Power Platform Inventory, supplements canvas connector evidence
through Admin Apps, and reads published/unpublished Dataverse app modules. Writes
premium, all-app, review, environment, coverage, failure, and resumable journal files.
Unknown metadata is never classified as standard. See README.md for coverage limits.

.PARAMETER TenantId
The operator's Microsoft Entra tenant GUID. No account or tenant is inferred.

.PARAMETER OutputDirectory
An empty private directory for a new scan, or the original directory with Resume.

.PARAMETER UseExistingContext
Use an existing Az user context in this tenant instead of opening interactive sign-in.

.PARAMETER AuthenticationMode
Auto selects Certificate or ClientSecret when native credentials are supplied;
otherwise it uses optional AzAccounts. All modes require delegated user sign-in.

.PARAMETER ClientId
The operator's confidential Web application (client) GUID for native authentication.

.PARAMETER ClientSecret
A SecureString secret for native delegated authorization-code authentication.
If ClientSecret mode is selected without this value, a secure prompt is shown.

.PARAMETER ClientCertificate
An RSA-PSS-capable X509 certificate with a private key registered on ClientId.
Obtain it with Get-Item Cert:\... or Get-PfxCertificate; never export the private key.

.PARAMETER RedirectUri
The application's registered Web loopback redirect URI. Default http://localhost:8400/.

.PARAMETER LoginTimeoutSeconds
Maximum time allowed for the browser user sign-in. Default 600 seconds.

.PARAMETER Resume
Validate and resume the original journal. Completed sources are not downloaded again.

.PARAMETER PageSize
Maximum requested records per page (1-1000). Keep the same value when resuming.

.PARAMETER RequestIntervalMilliseconds
Minimum delay after each HTTP attempt. Default 1000; server backoff always takes priority.

.PARAMETER MaxRetries
Maximum transient retries per request, in addition to the initial attempt. Default 8.

.PARAMETER RetryBudgetSeconds
Time budget per request's retry sequence. A longer server backoff stops the scan
rather than being shortened. Default 900 seconds.

.PARAMETER RequestTimeoutSeconds
Timeout for each HTTP attempt, including reading its response body. Default 120.

.EXAMPLE
.\Get-UnmanagedDeveloperPremiumApps.ps1 -TenantId 'YOUR-TENANT-GUID' -ClientId 'YOUR-CLIENT-GUID' -AuthenticationMode ClientSecret -OutputDirectory 'C:\Reports\DeveloperApps'

.EXAMPLE
pwsh -File .\Get-UnmanagedDeveloperPremiumApps.ps1 -TenantId 'YOUR-TENANT-GUID' -OutputDirectory 'C:\Reports\DeveloperApps' -Resume -UseExistingContext

.EXAMPLE
$certificate = Get-Item 'Cert:\CurrentUser\My\YOUR-CERTIFICATE-THUMBPRINT'
.\Get-UnmanagedDeveloperPremiumApps.ps1 -TenantId 'YOUR-TENANT-GUID' -ClientId 'YOUR-CLIENT-GUID' -ClientCertificate $certificate -OutputDirectory 'C:\Reports\DeveloperApps'

.NOTES
Exit codes: 0 = complete within documented scope, 1 = incomplete/failed,
2 = discovery finished but classification, environment metadata, or source drift needs review.
This script does not export apps, change permissions, or modify any tenant resource.
Supported engines: Windows PowerShell 5.1 and PowerShell 7.4+.
Native modes do not require Az.Accounts or its .NET Framework 4.7.2 minimum.
Certificate mode requires an RSA-PSS-capable platform/key provider.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1, 1000)][int]$PageSize = 1000,
    [ValidateRange(0, 60000)][int]$RequestIntervalMilliseconds = 1000,
    [ValidateRange(0, 12)][int]$MaxRetries = 8,
    [ValidateRange(1, 86400)][int]$RetryBudgetSeconds = 900,
    [ValidateRange(1, 600)][int]$RequestTimeoutSeconds = 120,
    [switch]$Resume,
    [switch]$UseExistingContext,
    [ValidateSet('Auto', 'AzAccounts', 'ClientSecret', 'Certificate')][string]$AuthenticationMode = 'Auto',
    [guid]$ClientId,
    [securestring]$ClientSecret,
    [Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,
    [string]$RedirectUri = 'http://localhost:8400/',
    [ValidateRange(30, 1800)][int]$LoginTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.psm1') -Force -ErrorAction Stop
    $nativeSecret = $AuthenticationMode -eq 'ClientSecret' -or
        ($AuthenticationMode -eq 'Auto' -and $null -eq $ClientCertificate -and $ClientId -ne [guid]::Empty)
    if (($nativeSecret -or $null -ne $ClientCertificate -or $AuthenticationMode -eq 'Certificate') -and
        $ClientId -eq [guid]::Empty) {
        throw 'ClientId is required for native client-secret/certificate authentication.'
    }
    if ($nativeSecret -and $null -eq $ClientSecret) {
        $PSBoundParameters.ClientSecret = Read-Host 'Application client secret (not your user password)' -AsSecureString
    }
    $summary = Invoke-DeveloperPremiumInventory @PSBoundParameters
    $summary
    exit $summary.ExitCode
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
