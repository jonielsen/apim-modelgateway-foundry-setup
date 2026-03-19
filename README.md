# Azure API Management → Azure AI Foundry Model Gateway

This repo contains the Bicep templates and parameter files to set up an **Azure API Management (APIM)** instance as a model gateway for **Azure AI Foundry agents**, including a working end-to-end example using `gpt-4.1`.

> **Related**: [foundry-samples](https://github.com/microsoft-foundry/foundry-samples) — the official Microsoft Foundry samples repo this builds on.

---

## Files

| File | Purpose |
|---|---|
| `apim-provision.bicep` | Creates the APIM Standard v2 instance with system-assigned managed identity |
| `apim-import-api.bicep` | Imports the Azure OpenAI API spec into APIM, sets the backend URL, and configures managed identity auth policy |
| `apim-connection-parameters.json` | Foundry connection parameters (fill in your values, see Step 5) |

The Foundry connection Bicep template is consumed from the foundry-samples repo:
`foundry-samples/infrastructure/infrastructure-setup-bicep/01-connections/apim/connection-apim.bicep`

---

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- An **Azure AI Foundry project** already created
- Collect these values upfront:
  - Subscription ID
  - Resource Group name
  - Foundry Account name (`Microsoft.CognitiveServices/accounts` resource)
  - Foundry Project name
  - Azure OpenAI model deployment name and version

---

## Step 1: Create the APIM Instance

> ⚠️ **Important**: Use the Bicep template — `az apim create` does **not** support `StandardV2`.
> ⚠️ The `identity: { type: 'SystemAssigned' }` block is **required**. Without it, Step 3's managed identity policy will fail.

```bash
az deployment group create \
  --resource-group YOUR-RG \
  --template-file apim-provision.bicep \
  --name apim-provision
```

Provisioning takes ~15–20 minutes. Check status:

```bash
az deployment group show \
  --resource-group YOUR-RG \
  --name apim-provision \
  --query "properties.provisioningState" -o tsv
```

---

## Step 2: Grant APIM Identity Access to Azure OpenAI

APIM uses its system-assigned managed identity to call the Azure OpenAI backend. It needs the **Cognitive Services OpenAI User** role on your AI Services account.

```bash
# Get the APIM managed identity principal ID
PRINCIPAL_ID=$(az rest --method get \
  --url "https://management.azure.com/subscriptions/YOUR-SUB/resourceGroups/YOUR-RG/providers/Microsoft.ApiManagement/service/YOUR-APIM-NAME?api-version=2024-05-01" \
  --query "identity.principalId" -o tsv)

# Assign the role
az role assignment create \
  --role "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd" \
  --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/YOUR-SUB/resourceGroups/YOUR-RG/providers/Microsoft.CognitiveServices/accounts/YOUR-AI-SERVICES-ACCOUNT"
```

This is also handled automatically if you deploy `apim-import-api.bicep` (which includes a role assignment resource).

---

## Step 3: Import the Azure OpenAI API into APIM

> ⚠️ **Gotcha — Backend URL**: The `backendUrl` **must** include the `/openai` suffix:
> `https://YOUR-ACCOUNT.cognitiveservices.azure.com/openai`
> Without it, APIM strips the path prefix and the backend receives `/deployments/...` instead of `/openai/deployments/...`, causing a **404**.
>
> ⚠️ **Gotcha — Authentication**: The APIM policy uses `<authentication-managed-identity>` to acquire an Entra token and forward it as `Authorization: Bearer`. Without this the backend returns **401**.

Edit `apim-import-api.bicep` and set `backendUrl` to your endpoint, then deploy:

```bash
az deployment group create \
  --resource-group YOUR-RG \
  --template-file apim-import-api.bicep \
  --name apim-import-api
```

---

## Step 4: Smoke Test APIM

Verify end-to-end before creating the Foundry connection.

**Get the APIM master subscription key:**
```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/YOUR-SUB/resourceGroups/YOUR-RG/providers/Microsoft.ApiManagement/service/YOUR-APIM-NAME/subscriptions/master/listSecrets?api-version=2022-08-01" \
  --query "primaryKey" -o tsv
```

**Test chat completions:**
```bash
curl -X POST "https://YOUR-APIM.azure-api.net/openai/deployments/YOUR-DEPLOYMENT/chat/completions?api-version=2025-04-01-preview" \
  -H "Ocp-Apim-Subscription-Key: YOUR-APIM-KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":10}'
```

✅ Expect HTTP 200 before proceeding to Step 5.

> ⚠️ **Gotcha — Validation script**: The `test_apim_connection.py` script in the foundry-samples repo sends `api-key` header. APIM requires `Ocp-Apim-Subscription-Key`. Use the curl test above to confirm connectivity independently.

---

## Step 5: Create the Foundry APIM Connection

Edit `apim-connection-parameters.json` and replace all `YOUR-*` placeholders with your values.

> ⚠️ **Gotcha — `deploymentInPath`**: Must be `"true"` for Azure OpenAI. The deployment name is in the URL path (`/deployments/{name}/chat/completions`).
>
> ⚠️ **Gotcha — `inferenceAPIVersion`**: Set this to your api-version (e.g. `2025-04-01-preview`). Foundry appends `?api-version=...` to all requests — APIM passes it through to the backend. Do **not** leave this empty.

```bash
az deployment group create \
  --resource-group YOUR-RG \
  --template-file foundry-samples/infrastructure/infrastructure-setup-bicep/01-connections/apim/connection-apim.bicep \
  --parameters @apim-connection-parameters.json \
  --name apim-foundry-connection
```

---

## Common Failures & Fixes

| Symptom | Root Cause | Fix |
|---|---|---|
| `az apim create` fails with `StandardV2` not valid | CLI doesn't support this SKU | Use `apim-provision.bicep` instead |
| **404** from APIM backend | `backendUrl` missing `/openai` suffix | Change to `https://YOUR-ACCOUNT.cognitiveservices.azure.com/openai` |
| **401** from APIM backend | Managed identity not configured or RBAC not assigned | Verify `identity.principalId` is set; check `Cognitive Services OpenAI User` role assignment |
| **401** when using validation script | Script sends `api-key` header, APIM needs `Ocp-Apim-Subscription-Key` | Use the curl test in Step 4 to validate independently |
| Agent gets **DeploymentNotFound** | `deploymentInPath` is `false` | Set `"deploymentInPath": "true"` in parameters |
| Agent sends wrong api-version | `inferenceAPIVersion` left empty | Set to the api-version your deployment supports (e.g. `2025-04-01-preview`) |
| APIM can't acquire Entra token | `SystemAssigned` identity not enabled when APIM was created | Redeploy `apim-provision.bicep` with `identity: { type: 'SystemAssigned' }` added — it's a fast incremental update |
