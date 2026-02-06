# Trigger Power Automate Flow via HTTP with OAuth Authentication

This script allows you to trigger a Power Automate flow using an HTTP request with Azure AD OAuth authentication (service principal / app registration).

## Prerequisites

- Azure AD tenant with permissions to create App Registrations
- A Power Automate flow with an HTTP request trigger
- PowerShell 5.1 or later

---

## Step 1: Create an App Registration in Azure AD

1. Go to [Azure Portal](https://portal.azure.com) → **Microsoft Entra ID** → **App registrations**

2. Click **+ New registration**
   - **Name:** `Power Automate Flow Trigger` (or your preferred name)
   - **Supported account types:** `Accounts in this organizational directory only`
   - Click **Register**

3. On the app's **Overview** page, copy:
   - **Application (client) ID** → This is your `AppId`
   - **Directory (tenant) ID** → This is your `TenantId`

4. Go to **Certificates & secrets** → **Client secrets** → **+ New client secret**
   - **Description:** `FlowTriggerSecret`
   - **Expires:** Choose your preferred expiration
   - Click **Add**
   - ⚠️ **Copy the secret Value immediately** (you won't see it again) → This is your `ClientSecret`

5. Go to **Enterprise applications** → Search for your app name → Open it
   - Copy the **Object ID** from this page → This is your `ServicePrincipalObjectId`
   
   > **Important:** This is the Enterprise App (Service Principal) Object ID, NOT the App Registration Object ID. They are different!

---

## Step 2: Configure Your Power Automate Flow

1. Open your flow in [Power Automate](https://make.powerautomate.com)

2. Edit the flow and click on the **"When an HTTP request is received"** trigger

3. In the trigger configuration panel:
   - Set **"Who can trigger the flow?"** to **"Specific users in my tenant"**
   - In **"Allowed users"**, paste your **Service Principal Object ID**

4. **Save** the flow

5. Copy the **HTTP POST URL** from the trigger (you'll need this for the script)

---

## Step 3: Run the Script

### Option A: Using Parameters (Recommended)

```powershell
.\TriggerPowerAutomateFlowHttp.ps1 `
    -TenantId "your-tenant-id" `
    -AppId "your-app-id" `
    -ClientSecret "your-client-secret" `
    -WebHookUri "https://your-flow-url..."
```

### Option B: With Request Body

```powershell
.\TriggerPowerAutomateFlowHttp.ps1 `
    -TenantId "your-tenant-id" `
    -AppId "your-app-id" `
    -ClientSecret "your-client-secret" `
    -WebHookUri "https://your-flow-url..." `
    -RequestBody '{"key": "value"}'
```

### Option C: Edit Default Values in Script

Edit the script's default parameter values directly, then run:

```powershell
.\TriggerPowerAutomateFlowHttp.ps1
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `TenantId` | Yes | Your Azure AD Tenant ID |
| `AppId` | Yes | Application (Client) ID from App Registration |
| `ClientSecret` | Yes | Client secret value |
| `WebHookUri` | Yes | HTTP POST URL from your flow trigger |
| `RequestBody` | No | JSON body to send to the flow (optional) |

---

## Troubleshooting

### Error: `MisMatchingOAuthClaims`

**Cause:** The flow doesn't recognize your service principal.

**Fix:**
- Ensure you added the **Service Principal Object ID** (from Enterprise Applications), not the App Registration Object ID
- Verify the flow is set to "Specific users in my tenant"
- Re-save the flow after adding the allowed user

### Error: `AADSTS7000215: Invalid client secret`

**Cause:** Client secret is incorrect or expired.

**Fix:** Generate a new client secret in Azure AD and update the script.

### Error: `AADSTS700016: Application not found`

**Cause:** App ID is incorrect or the app was deleted.

**Fix:** Verify the App ID in Azure AD → App registrations.

---

## Security Notes

- Store client secrets securely (Azure Key Vault, encrypted credential stores)
- Use short-lived secrets and rotate regularly
- Consider using Managed Identity if running from Azure resources
- Limit the Service Principal's access to only the flows it needs to trigger

---

## References

- [Microsoft Docs: OAuth Authentication for HTTP Request Triggers](https://learn.microsoft.com/en-us/power-automate/oauth-authentication)
- [Microsoft Authentication Library (MSAL)](https://learn.microsoft.com/en-us/azure/active-directory/develop/msal-overview)
