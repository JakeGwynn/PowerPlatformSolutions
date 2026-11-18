# Maintainer solution build

End users should [download/import the solution ZIP](../Solutions/README.md).
These scripts are offline source/build/validation tooling only. They do not
connect to a tenant, export/import a live solution, publish a flow, create a
publisher/connection, or grant permissions.

## Provenance and layout

`templates\Solution.xml`, `templates\Customizations.xml` and
`templates\Workflow.xml` are sanitized structural metadata from the genuine
unmanaged Dataverse export of the cleaned, tested collector. Source publisher,
component identities, connection bindings, enabled state and captured definition
were not published. The workflow body is generated afresh from the current source,
with **no explicit `secureData` settings**, rather than copying the old export's
secured definition.

`SolutionProfiles.json` records stable, distinct Public/GCC solution names,
portable workflow GUIDs and logical reference names. These are **template
component IDs**, not tenant/user/source-workflow identities. Preserve them across
updates within a variant; do not casually regenerate them or reuse demo IDs.
The neutral offline publisher is `PowerPlatformSolutions` / prefix `fhr`.
No extra publisher was created in the source tenant to obtain these packages.

Text environment-variable XML follows Microsoft's exported solution format;
workflow parameters bind through `metadata.schemaName` as in the exported
PowerCAT sample. Tenant/site definitions are required without defaults/current
values. Folder has only its portable default. PAC `create-settings` recognizes
all three definitions and both unbound connector references.

## Rebuild

Install PAC separately if it is not already available. No automatic dependency
install, execution-policy change, repository-trust change or sign-in occurs.

```powershell
# From CloudFlow\packaging. Use a new directory or version; existing outputs fail.
.\Build-Solutions.ps1 -OutputDirectory "$env:TEMP\flow-history-build" -Verbose

# Later release; stable component IDs/profile names are retained.
.\Build-Solutions.ps1 -Version '1.0.0.1' `
    -OutputDirectory "$env:TEMP\flow-history-build-next"
```

The builder creates a new private temporary unpacked solution tree for each
variant, adds generated workflow/definitions and portable logical references,
then runs **`pac solution pack --packagetype Unmanaged`** and
**`pac solution create-settings`**. Every final workflow has Off/Draft metadata.
No raw-flow wrapper is renamed into a ZIP. Newly created temporary build trees
are removed afterward; existing output ZIPs are never overwritten.

ZIP timestamps can change a rebuild's byte hash without changing the solution
components. The published v1.0.0.0 files are the **exact byte streams** independently
staged/inspected; do not replace them with a different-byte rebuild and claim
the replacement had the same staging validation.

## Verify

```powershell
# Existing published ZIPs; tests run PAC unpack -> pack -> unpack for BOTH variants.
powershell.exe -NoProfile -File .\Test-SolutionPackages.ps1
pwsh.exe -NoProfile -File .\Test-SolutionPackages.ps1

# Private rebuild output.
.\Test-SolutionPackages.ps1 -SolutionDirectory "$env:TEMP\flow-history-build" `
    -ResultsPath "$env:TEMP\flow-history-package-checks.json"

# Related source/expression fixtures, using each installed engine/profile.
powershell.exe -NoProfile -File ..\tests\Invoke-Tests.ps1 -Cloud Public
powershell.exe -NoProfile -File ..\tests\Invoke-Tests.ps1 -Cloud GCC
pwsh.exe -NoProfile -File ..\tests\Invoke-Tests.ps1 -Cloud Public
pwsh.exe -NoProfile -File ..\tests\Invoke-Tests.ps1 -Cloud GCC
```

Checks cover ZIP structure, unmanaged flag, exact collector/ref/config counts,
Off/Draft state, native wrapper/reference consistency, no bound identities/site/
credentials/current values, every cloud route, and zero explicit Secure Inputs/
Outputs across the entire packaged action/trigger tree. Required SecureObject
authentication remains; report withholding/host guards are separately retained.
`RootComponents` order is normalized only for semantic round-trip comparison:
PAC can reorder those set-like declarations without changing their meaning.

PAC can warn that standalone environment-variable root components are not in
`customizations.xml`; the definitions are separate ZIP entries. Do not ignore a
genuine missing component: verify the exact entries, PAC-generated settings and
native staging results. The accepted ZIPs contain all three definitions, and the
platform staging operation recognized them without missing dependencies.

Offline pack/round-trip results do not prove an environment import or runtime.
The coordinator additionally ran **Dataverse StageSolution** against the exact
released Public/GCC bytes: both passed with no missing dependencies/validation
errors, without installing components or calling GCC. A later changed package
needs its own evidence. The original organic Dataverse-trigger, government/
other-tenant runtime, privacy, retention and native performance limits still apply.

References:

- [Microsoft PAC SolutionPackager](https://learn.microsoft.com/en-us/power-platform/alm/solution-packager-tool)
- [Solution pack/unpack/create-settings commands](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/solution)
- [Exporting solution-aware flows and required references/definitions](https://learn.microsoft.com/en-us/power-automate/export-flow-solution)
- [Environment variables and import-time values](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/environmentvariables)
- [First-party exported Text variable definition](https://github.com/microsoft/powercat-business-approvals-kit/blob/786b456f0643ef2b6d3109f5dc2f71de05a07dc6/BusinessApprovalKit/SolutionPackage/src/environmentvariabledefinitions/cat_ApprovalKitOrgUrl/environmentvariabledefinition.xml)
- [First-party exported parameter metadata.schemaName](https://github.com/microsoft/powercat-business-approvals-kit/blob/786b456f0643ef2b6d3109f5dc2f71de05a07dc6/BusinessApprovalKit/SolutionPackage/src/Workflows/BACoreRuntime-StartStage-FB00D840-CA8C-EC11-8D20-000D3A09D351.json)
- [Native StageSolution request](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/reference/stagesolution?view=dataverse-latest)
