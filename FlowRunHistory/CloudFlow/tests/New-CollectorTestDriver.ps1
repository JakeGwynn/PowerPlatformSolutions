#Requires -Version 5.1

<#
.SYNOPSIS
Generates an offline native child-flow test driver with literal test inputs.

.DESCRIPTION
The driver and collector must be in the same authorized unmanaged solution.
CollectorWorkflowId is the solution/Dataverse workflow GUID, not an anonymous
trigger URL or the runtime Logic Apps resource ID. No deployment/sign-in occurs.
The driver has a no-argument Button trigger; its Workflow action supplies the
literal body to the collector. Change this task-owned driver, not production
collector inputs/defaults, between test cases.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CollectorWorkflowId,
    [Parameter(Mandatory)][ValidateNotNull()][hashtable]$InputParameters,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($CollectorWorkflowId -eq [guid]::Empty) { throw 'CollectorWorkflowId must be the verified nonempty solution workflow GUID.' }
$allowed = @('EnvironmentId', 'FlowIds', 'RunIds', 'Status', 'Mode', 'IncludeCallingRecordId', 'IdOnly',
    'RecordSource', 'PrimaryKeyMap', 'LastDays', 'FromUtc', 'ToUtc', 'ExportFormat', 'AsAdmin',
    'ExcludedFlowIds', 'MaxWorkItems', 'MaxRuns')
foreach ($key in $InputParameters.Keys) {
    if ($key -cnotin $allowed) { throw "Unknown collector input: $key" }
    if ($InputParameters[$key] -is [string] -and $InputParameters[$key].StartsWith('@')) {
        throw 'Test inputs must be literal values, not WDL expressions.'
    }
}
$package = [pscustomobject][ordered]@{
    displayName = 'Flow History Collector - Native Test Driver'
    state = 'Stopped'
    definition = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            '$authentication' = @{ type = 'SecureObject'; defaultValue = @{} }
            '$connections' = @{ type = 'Object'; defaultValue = @{} }
        }
        triggers = @{
            manual = @{ type = 'Request'; kind = 'Button'; inputs = @{ schema = @{ type = 'object'; properties = @{} } } }
        }
        actions = @{
            Call_collector = @{
                type = 'Workflow'
                inputs = @{
                    host = @{ workflowReferenceName = $CollectorWorkflowId.ToString() }
                    body = $InputParameters
                }
                runAfter = @{}
            }
        }
        outputs = @{}
    }
    connectionReferences = @{}
    deployment = @{
        automaticDeployment = $false
        sameSolutionRequired = $true
        collectorWorkflowId = $CollectorWorkflowId.ToString()
        referenceKind = 'Solution/Dataverse workflow GUID, literal native workflowReferenceName'
        warning = 'Create/activate only through the approved tenant/solution lifecycle. Do not rely on classic management manual/run body transmission.'
        contractSources = @(
            'https://learn.microsoft.com/en-us/power-automate/create-child-flows',
            'https://github.com/microsoft/CopilotStudioSamples/blob/b243a7265db85df6ff608f925167edd048b278f9/infrastructure/manage-paygo/sourcecode/Workflows/PollCostandUnlinkEnvironments-AE89C8E6-2544-F111-BEC7-7C1E520AA4DF.json'
        )
    }
}
if ($OutputPath) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = $null
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.WriteLine((ConvertTo-Json -InputObject $package -Depth 100))
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        else { $stream.Dispose() }
    }
}
$package
