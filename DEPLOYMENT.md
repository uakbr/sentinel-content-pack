# Deployment Guide

## Manual Configuration Issues Solved

This automation eliminates the following manual steps that teams typically struggle with:

### What Used to Be Manual

1. **API Connections** - Creating OAuth connections for:
   - Azure Sentinel
   - Azure AD / Microsoft Graph
   - Microsoft Teams
   - Office 365
   - Microsoft Defender

2. **RBAC Permissions** - Assigning roles to Logic Apps:
   - Azure Sentinel Responder
   - Azure Sentinel Contributor
   - User Access Administrator
   - Security Admin

3. **Managed Identity** - Enabling system-assigned identities for Logic Apps

4. **Parameters** - Manually entering values for each deployment

5. **Watchlist Import** - Uploading CSV files one by one

6. **Connection Authorization** - Clicking through OAuth flows in portal

## Automated Deployment

### Prerequisites

```bash
# Install Azure CLI
brew install azure-cli

# Login
az login

# Set subscription
az account set --subscription "<your-subscription-id>"

# Install Sentinel extension
az extension add --name sentinel
```

### Quick Start

#### 1. Configure Parameters

```bash
# Copy template
cp deployment/parameters.template.json deployment/parameters.json

# Edit with your values
nano deployment/parameters.json
```

Required values:
- `workspaceName`: Your Sentinel workspace name
- `workspaceResourceGroup`: Resource group containing Sentinel
- `teamsWebhookUrl`: Teams webhook for notifications
- `decisionEngineUrl`: Your decision engine endpoint (or use placeholder)

#### 2. Deploy Everything

```bash
# One command deploys all content
./scripts/deploy-all.sh <resource-group> <workspace-name> deployment/parameters.json
```

This will:
1. Create/verify resource group
2. Deploy API connections
3. Deploy analytics rules
4. Deploy playbooks
5. Import watchlists
6. Configure RBAC permissions

#### 3. Authorize Connections

```bash
# This opens your browser to authorize each connection
./scripts/setup-connections.sh <resource-group>
```

Click "Authorize" for each connection when prompted.

#### 4. Validate Deployment

```bash
# Verify everything is working
./scripts/validate-deployment.sh <resource-group> <workspace-name>
```

## Individual Component Deployment

### Deploy Only API Connections

```bash
az deployment group create \
  --resource-group <rg> \
  --template-file deployment/api-connections.json \
  --parameters workspaceName=<workspace> \
  --parameters workspaceResourceGroup=<workspace-rg>
```

### Deploy Single Playbook

```bash
az deployment group create \
  --resource-group <rg> \
  --template-file playbooks/pb-disable-user.json \
  --parameters @deployment/parameters.json \
  --parameters logicAppName=sentinel-disable-user
```

### Import Single Watchlist

```bash
az sentinel watchlist create \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --watchlist-alias high_value_assets \
  --display-name "High Value Assets" \
  --provider "Sentinel Content Pack" \
  --source "LocalFile" \
  --source-type "Local file"

az sentinel watchlist-item create \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --watchlist-alias high_value_assets \
  --properties-file watchlists/high_value_assets.csv
```

### Configure RBAC Manually

```bash
# Enable managed identity for Logic App
az resource update \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type "Microsoft.Logic/workflows" \
  --set identity.type=SystemAssigned

# Get principal ID
PRINCIPAL_ID=$(az resource show \
  --resource-group <rg> \
  --name <logic-app-name> \
  --resource-type "Microsoft.Logic/workflows" \
  --query "identity.principalId" -o tsv)

# Assign roles
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Azure Sentinel Responder" \
  --scope <workspace-resource-id>
```

## Multi-Tenant Deployment

Deploy to multiple environments using parameter files:

```bash
# Production
./scripts/deploy-all.sh rg-sentinel-prod sentinel-prod deployment/parameters.prod.json

# Staging
./scripts/deploy-all.sh rg-sentinel-staging sentinel-staging deployment/parameters.staging.json

# Development
./scripts/deploy-all.sh rg-sentinel-dev sentinel-dev deployment/parameters.dev.json
```

## CI/CD Integration

### Azure DevOps Pipeline

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - analytics/*
      - playbooks/*
      - watchlists/*

variables:
  resourceGroup: 'rg-sentinel-prod'
  workspaceName: 'sentinel-workspace-prod'

stages:
- stage: Deploy
  jobs:
  - job: DeployContent
    pool:
      vmImage: 'ubuntu-latest'
    steps:
    - task: AzureCLI@2
      displayName: 'Deploy Sentinel Content'
      inputs:
        azureSubscription: 'Azure-ServiceConnection'
        scriptType: 'bash'
        scriptLocation: 'scriptPath'
        scriptPath: 'scripts/deploy-all.sh'
        arguments: '$(resourceGroup) $(workspaceName) deployment/parameters.json'
    
    - task: AzureCLI@2
      displayName: 'Validate Deployment'
      inputs:
        azureSubscription: 'Azure-ServiceConnection'
        scriptType: 'bash'
        scriptLocation: 'scriptPath'
        scriptPath: 'scripts/validate-deployment.sh'
        arguments: '$(resourceGroup) $(workspaceName)'
```

### GitHub Actions

```yaml
name: Deploy Sentinel Content

on:
  push:
    branches: [main]
    paths:
      - 'analytics/**'
      - 'playbooks/**'
      - 'watchlists/**'

env:
  RESOURCE_GROUP: rg-sentinel-prod
  WORKSPACE_NAME: sentinel-workspace-prod

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      
      - name: Deploy Content
        run: |
          chmod +x scripts/*.sh
          ./scripts/deploy-all.sh ${{ env.RESOURCE_GROUP }} ${{ env.WORKSPACE_NAME }} deployment/parameters.json
      
      - name: Validate
        run: |
          ./scripts/validate-deployment.sh ${{ env.RESOURCE_GROUP }} ${{ env.WORKSPACE_NAME }}
```

## Troubleshooting

### Connection Authorization Fails

**Issue:** API connections show "Unauthenticated"

**Solution:**
```bash
# Re-run setup script
./scripts/setup-connections.sh <resource-group>

# Or manually in portal:
# Azure Portal > Resource Groups > <rg> > Connections > <connection> > Edit API connection > Authorize
```

### Logic App Missing Permissions

**Issue:** Playbook fails with "Forbidden" error

**Solution:**
```bash
# Re-run RBAC configuration
./scripts/configure-rbac.sh <resource-group> <workspace-name>
```

### Analytics Rule Deployment Fails

**Issue:** Rule already exists or invalid KQL

**Solution:**
```bash
# Delete existing rule
az sentinel alert-rule delete \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --alert-rule <rule-id>

# Validate KQL in Sentinel portal before deploying
```

### Watchlist Import Fails

**Issue:** CSV format incorrect

**Solution:**
- Ensure CSV has headers
- Check for special characters
- Verify encoding (UTF-8)

## Parameter Reference

### Required Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `workspaceName` | Sentinel workspace name | `sentinel-prod` |
| `workspaceResourceGroup` | Resource group with workspace | `rg-sentinel` |
| `location` | Azure region | `eastus` |

### Optional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `logicAppNamePrefix` | Prefix for Logic Apps | `sentinel-playbook` |
| `enableAutoRemediation` | Auto-remediate without approval | `false` |
| `teamsWebhookUrl` | Teams notification webhook | None |
| `decisionEngineUrl` | Policy engine endpoint | None |
| `tags` | Resource tags | `{}` |

## What Gets Deployed

### Infrastructure
- 5 API Connections (Sentinel, Azure AD, Teams, Office365, Defender)
- Managed Identities for all Logic Apps
- RBAC role assignments

### Security Content
- Analytics rules from `analytics/` folder
- Playbooks from `playbooks/` folder
- Watchlists from `watchlists/` folder
- Workbooks from `workbooks/` folder

### Permissions Assigned
- **Azure Sentinel Responder** - Read/write incidents
- **Azure Sentinel Contributor** - Manage Sentinel resources
- **User Access Administrator** - Disable user accounts
- **Security Admin** - Defender endpoint actions

## Cost Estimate

| Resource | Monthly Cost (approx) |
|----------|----------------------|
| Logic App executions (1000/month) | $0.50 |
| API Connection | $0.00 |
| Sentinel analytics rules | $0.00 |
| Log Analytics ingestion (5GB/day) | $12.50 |
| **Total** | **~$13/month** |

## Security Considerations

### Least Privilege
- Use managed identities instead of service principals
- Assign minimal required roles
- Enable conditional access for Logic Apps

### Secrets Management
- Store sensitive values in Azure Key Vault
- Reference Key Vault in parameters:
  ```json
  {
    "teamsWebhookUrl": {
      "reference": {
        "keyVault": {
          "id": "/subscriptions/.../vaults/myvault"
        },
        "secretName": "teams-webhook"
      }
    }
  }
  ```

### Audit Logging
- Enable Logic App diagnostic logs
- Send to Log Analytics workspace
- Monitor failed authorizations

## Support

If you encounter issues:

1. Run validation script: `./scripts/validate-deployment.sh <rg> <workspace>`
2. Check deployment logs in Azure Portal
3. Review Logic App run history
4. Open GitHub issue with error details

## Next Steps

After deployment:

1. **Configure Automation Rules**
   - Go to Sentinel > Configuration > Automation
   - Create rules to trigger playbooks on incident creation
   - Example: "On incident with high severity, run pb-disable-user"

2. **Test Playbooks**
   - Create test incident in Sentinel
   - Manually trigger playbook
   - Verify actions complete successfully

3. **Customize Content**
   - Modify KQL queries in analytics rules
   - Adjust playbook workflows for your environment
   - Add custom watchlist data

4. **Enable Monitoring**
   - Set up alerts for failed playbook runs
   - Monitor MTTR metrics
   - Review automation coverage

