# Finding the HTTP Trigger URL in Power Automate

This guide explains how to locate and understand the HTTP trigger URL for Power Automate flows, including the different URL formats based on authentication settings.

## HTTP Trigger URL Structure

The HTTP trigger URL format varies depending on the **"Who can trigger the flow?"** setting in your flow's HTTP trigger configuration.

### URL Components

| Component | Description |
|-----------|-------------|
| `a6103daff924e0eea58d3bc2f25fbf.1d` | Environment ID with a period inserted before the last two characters (actual ID: `a6103daff924e0eea58d3bc2f25fbf1d`) |
| `9cf308abcd8f4e6eaf6c7e35dc3a4312` | Flow ID (workflow ID) |
| `api-version=1` | API version parameter |

> **Note:** The environment ID in the URL has a period (`.`) inserted before the last two characters. For example, environment ID `a6103daff924e0eea58d3bc2f25fbf1d` becomes `a6103daff924e0eea58d3bc2f25fbf.1d` in the URL.

---

## URL Formats by Authentication Setting

### 1. "Anyone in my tenant" or "Specific users in my tenant"

When you configure the trigger to allow **"Anyone in my tenant"** or **"Specific users in my tenant"**, you get a clean URL without signature parameters:

```
https://<environment-id>.1d.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/<flow-id>/triggers/manual/paths/invoke?api-version=1
```

**Example:**
```
https://a6103daff924e0eea58d3bc2f25fbf.1d.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/9cf308abcd8f4e6eaf6c7e35dc3a4312/triggers/manual/paths/invoke?api-version=1
```

> **Note:** These URLs require OAuth authentication (bearer token) to invoke the flow.

---

### 2. "Anyone" (Public/Anonymous Access)

When you configure the trigger to allow **"Anyone"**, the URL includes signature parameters (`sig`, `sp`, `sv`) that act as a shared access key:

```
https://<environment-id>.1d.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/<flow-id>/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signature>
```

**Example:**
```
https://a6103daff924e0eea58d3bc2f25fbf.1d.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/9cf308abcd8f4e6eaf6c7e35dc3a4312/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=Skj4F2kd5fCosBUb_94Ej13Gv7IUmwNUgWBS13PEgU
```

**Additional URL Parameters:**

| Parameter | Description |
|-----------|-------------|
| `sp` | Signature permissions (URL encoded: `/triggers/manual/run`) |
| `sv` | Signature version |
| `sig` | Signature key (shared access signature) |

> ⚠️ **Security Warning:** URLs with the `sig` parameter can be called by anyone with the URL. Treat them like a password and do not share publicly.

---

## Retrieving the Callback URL Programmatically

You can use the **List Callback URL** API endpoint to retrieve the trigger URL programmatically. This is useful for automation scenarios or when you need to get the current callback URL dynamically.

### List Callback URL Endpoint

```
https://<environment-id>.1d.environment.api.powerplatform.com/powerautomate/flows/<flow-guid>/triggers/manual/listCallbackUrl?api-version=1&showDeprecatedCallbackUrl=false
```

**Example:**
```
https://a6103daff924e0eea58d3bc2f25fbf.1d.environment.api.powerplatform.com/powerautomate/flows/172fbd25-dda7-45bd-a634-a0295d3c98c8/triggers/manual/listCallbackUrl?api-version=1&showDeprecatedCallbackUrl=false
```

### Key Differences in the Callback URL Endpoint

| Component | Invoke URL | Callback URL Endpoint |
|-----------|------------|----------------------|
| Path | `/powerautomate/automations/direct/workflows/<id>` | `/powerautomate/flows/<guid>` |
| Flow ID format | Workflow ID (no dashes) | Flow GUID (with dashes) |
| Purpose | Trigger the flow | Retrieve the trigger URL |

---

## How to Find the Trigger URL in the Power Automate Portal

1. Open [Power Automate](https://make.powerautomate.com)

2. Navigate to **My flows** and select your flow

3. Click **Edit** to open the flow designer

4. Click on the **"When an HTTP request is received"** trigger

5. The **HTTP URL** will be displayed in the trigger configuration panel
   - If the flow has been saved at least once, the URL will be populated
   - If the URL shows "URL will be generated after save", save the flow first

6. Click the **copy icon** next to the URL to copy it to your clipboard

---

## Finding Environment and Flow IDs

### Environment ID
- Found in the Power Automate portal URL when viewing a flow: `https://make.powerautomate.com/environments/<environment-id>/flows/...`
- Example: `https://make.powerautomate.com/environments/a6103daf-f924-e0ee-a58d-3bc2f25fbf1d/flows/172fbd25-dda7-45bd-a634-a0295d3c98c8/details`
- Can also be found in the Power Platform Admin Center under **Environments**

> **Note:** The environment ID in the portal URL is a GUID with dashes (`a6103daf-f924-e0ee-a58d-3bc2f25fbf1d`). In the HTTP trigger URL, the dashes are removed and a period is inserted before the last two characters (`a6103daff924e0eea58d3bc2f25fbf.1d`).

### Flow ID
- Found in the Power Automate portal URL after `/flows/`: `https://make.powerautomate.com/environments/.../flows/<flow-id>/details`
- Example: `172fbd25-dda7-45bd-a634-a0295d3c98c8`

> **Note:** The flow ID and workflow ID are the same. In the portal URL it appears as a GUID with dashes. In the HTTP trigger URL (after `/workflows/`), the dashes are removed.

---

## See Also

- [TriggerPowerAutomateFlowHttp.md](TriggerPowerAutomateFlowHttp.md) - How to trigger flows with OAuth authentication
- [TriggerPowerAutomateFlowHttp.ps1](TriggerPowerAutomateFlowHttp.ps1) - PowerShell script for triggering flows
