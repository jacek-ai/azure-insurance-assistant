# azure-insurance-assistant

Insurance assistant built on Azure AI Foundry + Azure AI Search (RAG) with **mandatory product selection** before retrieval. The goal is to help an insurance agent answer customer questions based on the correct OWU/terms for a **specific product and version**, avoiding mixing content across products.

## What it does (business)

- Lists available insurance products (including versions and validity dates).
- Forces the user (or the agent) to pick exactly one `product_id`.
- Retrieves only the chunks relevant to that product from the RAG index.

## High-level architecture

1. Azure AI Foundry agent receives a question.
2. Agent calls Azure Functions via an OpenAPI tool:
	- `list_products` to resolve the product context
	- `search_chunks` to retrieve RAG chunks filtered by `product_id`
3. Azure Functions access data plane resources using Managed Identity:
	- Blob Storage for product catalog (`products.json`)
	- Azure AI Search for chunk retrieval

Key files:

- Agent definition and instructions: [src/agent/create_agent.py](src/agent/create_agent.py)
- Tool schema and wiring: [src/agent/assets/function_openapi.json](src/agent/assets/function_openapi.json), [src/agent/tools/function_openapi_tool.py](src/agent/tools/function_openapi_tool.py)
- Function endpoints: [src/functions/hello-api/function_app.py](src/functions/hello-api/function_app.py)

## Azure resources (deployed with Bicep)

Infrastructure is defined in [infra/bicep/main.bicep](infra/bicep/main.bicep) and modularized in [infra/bicep/modules](infra/bicep/modules).

Core components:

- Azure AI Foundry (AIServices) + Project
- Model deployments:
  - `gpt-4o` (chat)
  - `text-embedding-3-small` (embeddings)
- Azure AI Search (used for RAG retrieval)
- Storage Account (Blob containers for RAG data and product catalog)
- Azure Functions (Linux Consumption, Python)
- Optional Key Vault (to store the Functions host key)

## Authentication and security model

This project uses two different security mechanisms, depending on the hop:

### Agent → Azure Functions (tool calls)

- Authentication is done with an Azure Functions key passed in the `x-functions-key` header.
- The key is stored in an Azure AI Foundry **Project Connection** of type **Custom keys**.

Default connection expected by the agent script:

- Connection name: `con-function-insurance-assistance`
- Key name: `x-functions-key`
- Key value: Function App → App keys → key named `default`

### Azure Functions → Storage / Search

- Uses `DefaultAzureCredential` (Managed Identity in Azure; developer credentials locally).
- RBAC assignments are deployed in [infra/bicep/modules/rbac.bicep](infra/bicep/modules/rbac.bicep).

### Search → Embeddings (for ingestion)

- Azure AI Search uses its managed identity to call the Azure OpenAI deployment for embeddings.

## RAG organization

Data sources:

- Product catalog in Blob Storage (default: container `products`, blob `products.json`).
- RAG documents in Blob Storage (default: container `rag-data`).

Indexing strategy (product isolation):

- Chunks in Azure AI Search include a `product_id` field.
- The indexing pipeline extracts `product_id` from the blob/file name (default delimiter `__`).
- Retrieval is always hard-filtered by `product_id` in the Functions endpoint.

Provisioning script (data plane):

- [src/search/indexing/create_knowledgesource.py](src/search/indexing/create_knowledgesource.py)
- JSON templates: [src/search/indexing/definitions](src/search/indexing/definitions)

## Deployment

1) Provision Azure infrastructure:

- Run [scripts/deploy.ps1](scripts/deploy.ps1)
- Optionally provide `FUNCTION_X_FUNCTIONS_KEY` to enable “single-secret wiring” (Functions key + Foundry connection).

2) Publish Azure Functions code (agent tools):

- Run [scripts/deploy-functions.ps1](scripts/deploy-functions.ps1)

3) (Optional) Verify wiring:

- Run [scripts/verify.ps1](scripts/verify.ps1)

## Agent setup (Foundry Project connection)

Environment variables required by the agent creation script [src/agent/create_agent.py](src/agent/create_agent.py):

- `AI_SERVICE_PROJECT_ENDPOINT`
- `FUNCTION_BASE_URL` (example: `https://<your-functionapp>.azurewebsites.net`)
- `FUNCTION_PROJECT_CONNECTION_NAME` (optional; defaults to `con-function-insurance-assistance`)

### Provisioning the connection via Bicep (recommended)

Infrastructure deployment can create the Project Connection automatically if you provide the Functions host key as a secure Bicep parameter (`functionXFunctionsKey`).

When `functionXFunctionsKey` is provided, the deployment also sets the Function App host key named `default` to that value so the same secret works end-to-end.

- Example parameters file: [infra/bicep/main.bicepparam.example](infra/bicep/main.bicepparam.example)

If `functionXFunctionsKey` is empty, the deployment skips creating the connection and you can still create it manually in the Foundry portal.

### Optional: create Key Vault via Bicep

Key Vault creation is implemented in [infra/bicep/modules/keyvault.bicep](infra/bicep/modules/keyvault.bicep) and is disabled by default.

To enable it, set parameters in `infra/bicep/main.bicepparam`:

- `createKeyVault = true`
- `keyVaultName = 'kv-...'`
- `keyVaultFunctionKeySecretName = 'functions-host-key-default'` (optional)

Note: even when creating the Key Vault, you still need to supply the secret value (`functionXFunctionsKey`) from a secure source (CI/CD secret, etc.).

## Local development

Prerequisites:

- Python 3.11
- Azure CLI (`az`) and access to the subscription
- Azure Functions Core Tools (`func`) for local Functions runs

Run Functions locally:

- Open [src/functions/hello-api/local.settings.json](src/functions/hello-api/local.settings.json) and fill required values.
- From [src/functions/hello-api](src/functions/hello-api): run `func start`

Create/update the agent:

- Configure environment variables (commonly via a local `.env`).
- Run [src/agent/create_agent.py](src/agent/create_agent.py)

## Repository structure

- [infra](infra): Bicep templates
- [scripts](scripts): deployment and verification scripts
- [src/agent](src/agent): agent definition + OpenAPI tool specification
- [src/functions/hello-api](src/functions/hello-api): Azure Functions endpoints used as agent tools
- [src/search/indexing](src/search/indexing): provisioning of Search knowledge source and index pipeline
