#Requires -Version 7.4

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
pwsh -File .\Get-UnmanagedDeveloperPremiumApps.ps1 -TenantId '<tenant-guid>' -OutputDirectory 'C:\Reports\DeveloperApps'

.EXAMPLE
pwsh -File .\Get-UnmanagedDeveloperPremiumApps.ps1 -TenantId '<tenant-guid>' -OutputDirectory 'C:\Reports\DeveloperApps' -Resume -UseExistingContext

.NOTES
Exit codes: 0 = complete within documented scope, 1 = incomplete/failed,
2 = discovery finished but classification, environment metadata, or source drift needs review.
This script does not export apps, change permissions, or modify any tenant resource.
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
    [switch]$UseExistingContext
)

$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Inventory.psm1') -Force -ErrorAction Stop
    $summary = Invoke-DeveloperPremiumInventory @PSBoundParameters
    $summary
    exit $summary.ExitCode
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
