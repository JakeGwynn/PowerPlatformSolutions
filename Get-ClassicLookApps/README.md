# Get Classic Look Apps - Setup Guide

This guide walks through the process of generating a report of all Power Platform environments and their apps. Because this process requires accessing every Dataverse environment, several setup steps are required to ensure proper permissions.

## Summary

| Step | Script/Flow | Run As | Purpose |
|------|-------------|--------|---------|
| 1 | `ApplySystemAdministratorRole...` flow | Global/PP Admin | Grant user System Admin in all environments |
| 2 | Azure Portal | Global/PP Admin | Create App Registration with Power Platform API permission |
| 3 | `Add-AppUserToAllEnvironments-pac cli.ps1` | User from Step 1 | Add App Registration as System Admin + PP Admin |
| 4 | `Get-ClassicLookApps-AppRegAuth.ps1` | App Registration | Generate the apps report |

---

## Prerequisites

- **Global Administrator** or **Power Platform Administrator** role in your tenant
- A user account (regular or service account) that will be granted System Administrator access
- An Azure AD App Registration with appropriate permissions
- PowerShell 7+ recommended
- Power Platform CLI (pac)

---

## Step 1: Grant System Administrator Role to User Account

By default, Global Administrators and Power Platform Administrators do **not** have the System Administrator role in Dataverse environments. This step grants that access.

### Instructions

1. Import and run the Power Automate flow: `ApplySystemAdministratorRoletoAllEnvironmentsforCurrentUser_20260114193333.zip`
2. This flow must be run by a **Global Admin** or **Power Platform Admin**
3. The flow will grant the System Administrator role to the specified user account in every Power Platform environment

> **Note:** You can use either a regular user account or a service account (which is technically a user account). MFA can be enabled on this account.

---

## Step 2: Create an App Registration

Create an Azure AD App Registration that will be used to authenticate to each Power Platform environment.

### Instructions

1. Go to the [Azure Portal](https://portal.azure.com) > **Azure Active Directory** > **App registrations**
2. Click **New registration**
3. Enter a name (e.g., "Power Platform Classic Apps Report")
4. Select **Accounts in this organizational directory only** for supported account types
5. Click **Register**
6. Note the **Application (client) ID** and **Directory (tenant) ID** - you'll need these later

### Add API Permissions

1. In your App Registration, go to **API permissions**
2. Click **Add a permission**
3. Select **APIs my organization uses** and search for **Power Platform API**
4. Select **Delegated permissions**
5. Check **EnvironmentManagement.Environments.Read** (Read Environments)
6. Click **Add permissions**
7. Click **Grant admin consent for [your tenant]**

### Create a Client Secret

1. Go to **Certificates & secrets**
2. Click **New client secret**
3. Add a description and select an expiration period
4. Click **Add**
5. **Copy the secret value immediately** - it won't be shown again

> ⚠️ **Important:** Client secrets should always be stored securely. Never commit secrets to source control or share them in plain text. Consider using Azure Key Vault or a similar secrets management solution.

---

## Step 3: Add App Registration as System Administrator & Power Platform Admin

After granting the user account System Administrator access and creating the App Registration, run the script to add the App Registration as a System Administrator in every environment. This also registers the app as a Power Platform Administrator.

### Why is this needed?

- The next script needs to authenticate to each Power Platform environment separately
- Using an account with MFA enabled would prompt for authentication at each environment
- An App Registration allows automated, non-interactive authentication
- **Power Platform Admin** permission is needed to list all environments
- **System Administrator** role in each environment is needed to access app data

### Install Power Platform CLI (pac)

The script will attempt to automatically install the pac CLI if it's not detected. If you need to install it manually:

```powershell
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
```

For other installation options, see the [official documentation](https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction).

### Run the Script

```powershell
.\Add-AppUserToAllEnvironments-pac cli.ps1 -ClientId "<Your-App-Registration-Client-Id>"
```

**Parameters:**
| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ClientId` | Yes | The Application (client) ID of your App Registration |
| `-RoleName` | No | Role to assign (default: "System Administrator") |
| `-SkipPacInstallCheck` | No | Skip pac CLI installation check |
| `-OutputCsvPath` | No | Path to export results to CSV |
| `-EnvironmentFilter` | No | Array of environment IDs to filter |

---

## Step 4: Generate the Classic Look Apps Report

With the App Registration now having System Administrator access in all environments and Power Platform Admin access at the tenant level, run the report generation script.

```powershell
.\Get-ClassicLookApps-AppRegAuth.ps1 -TenantId "<Your-Tenant-Id>" -ClientId "<Your-Client-Id>" -ClientSecret "<Your-Client-Secret>" -CloudEnvironment Commercial -OutputFolder "C:\Reports"
```

**Parameters:**
| Parameter | Required | Description |
|-----------|----------|-------------|
| `-TenantId` | Yes | The Azure AD Tenant ID |
| `-ClientId` | Yes | The Azure AD App Registration Client ID |
| `-ClientSecret` | Yes | The Azure AD App Registration Client Secret |
| `-CloudEnvironment` | Yes | The cloud environment: `Commercial`, `GCC`, or `GCCHigh` |
| `-OutputFolder` | Yes | The folder path where CSV files will be saved |
| `-EnvironmentFilter` | No | Filter for environment ID/name (only matching environments will be processed) |
| `-FullOutput` | No | Switch to display full app and environment tables (default shows summary only) |

This script will:
1. Authenticate using the App Registration
2. Connect to each Power Platform environment
3. Generate a report of all environments and apps
4. Output CSV files: `ClassicLookApps_YYYYMMDD_HHmmss_Apps.csv` and `ClassicLookApps_YYYYMMDD_HHmmss_Environments.csv`

---

## Security Recommendations

If you don't want a permanent account with System Administrator access to every environment, consider the following approach:

1. **Create a temporary service account** specifically for this process
2. Run the steps in this guide using that service account
3. **Delete the service account** after the report is generated
4. **Delete the App Registration** after the report is generated

This approach is **highly recommended** for security, as it avoids leaving permanent elevated access in your tenant.
