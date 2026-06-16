# Desktop flow logs verbosity (flowLogsVerbosity)

This lives in the `metadata` JSON on the `workflows` table for desktop flows (category 6, uiflowtype 2). When it's not set, the flow uses the default verbosity. Setting it to `Full` turns on full logging.

## Retrieve the current setting

```
GET /api/data/v9.2/workflows(<flowid>)?$select=name,metadata
```

Look at the `metadata` string. If you see `"flowLogsVerbosity":"Full"` it's on Full. If the key isn't there (or it's `null`), it's on default.

To find every flow that's currently set to Full:

```
GET /api/data/v9.2/workflows?$select=name,metadata&$filter=category eq 6 and uiflowtype eq 2 and contains(metadata,'"flowLogsVerbosity":"Full"')
```

## Change it to Full

Take the existing `metadata` JSON, add the `flowLogsVerbosity` key, and PATCH it back. Don't drop any of the other properties - send the whole thing.

```
PATCH /api/data/v9.2/workflows(<flowid>)
{
  "metadata": "{ ...all the existing props... ,\"flowLogsVerbosity\":\"Full\"}"
}
```

## Reset back to default

Same idea - just remove the `flowLogsVerbosity` key from the JSON and PATCH it back. That's what the portal does.

```
PATCH /api/data/v9.2/workflows(<flowid>)
{
  "metadata": "{ ...all the existing props, no flowLogsVerbosity key... }"
}
```

Setting the key to `null` instead of removing it also resets to default and the flow stays valid, but removing it is cleaner and matches the portal.

## Worked example (retrieve, then remove the property)

Using a real environment and flow id:

```
https://org1b8d9700.api.crm.dynamics.com/api/data/v9.2/workflows(c9f7fa8b-140b-4bb5-8f52-df076d61cfb4)?$select=name,metadata
```

In PowerShell:

```powershell
$apiBase = 'https://org1b8d9700.api.crm.dynamics.com/api/data/v9.2'
$flowId  = 'c9f7fa8b-140b-4bb5-8f52-df076d61cfb4'
$h       = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json' }

# 1. Retrieve the current metadata
$meta = (Invoke-RestMethod -Method Get -Headers $h `
    -Uri "$apiBase/workflows($flowId)?`$select=metadata").metadata

# 2. Remove the flowLogsVerbosity property (works whether it's "Full" or null)
$obj = $meta | ConvertFrom-Json
$obj.PSObject.Properties.Remove('flowLogsVerbosity')
$newMeta = $obj | ConvertTo-Json -Compress

# 3. PATCH it back
Invoke-RestMethod -Method Patch -Headers $h `
    -Uri "$apiBase/workflows($flowId)" `
    -Body (@{ metadata = $newMeta } | ConvertTo-Json)
```

After this the flow is back on default verbosity. To set Full instead, swap step 2 for `$obj | Add-Member -NotePropertyName flowLogsVerbosity -NotePropertyValue 'Full' -Force`.

## Notes

- Only PATCH the `metadata` column. Never touch `clientdata` - reading and writing that back corrupts the flow's RPA package.
- PATCH is a partial update, so sending just `metadata` leaves everything else alone.
