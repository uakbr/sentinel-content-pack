## Comprehensive Troubleshooting Guide

This guide covers EVERY possible failure scenario, edge case, and contingency for the Sentinel Content Pack deployment.

---

## Table of Contents

1. [Authentication & Authorization Issues](#authentication--authorization-issues)
2. [Network & Connectivity Problems](#network--connectivity-problems)
3. [Resource Conflicts & Naming](#resource-conflicts--naming)
4. [Permission & RBAC Errors](#permission--rbac-errors)
5. [API Connection Failures](#api-connection-failures)
6. [Deployment Failures](#deployment-failures)
7. [Resource Provider Issues](#resource-provider-issues)
8. [Quota & Throttling](#quota--throttling)
9. [Data & Format Errors](#data--format-errors)
10. [Version Compatibility](#version-compatibility)
11. [Azure Policy & Compliance](#azure-policy--compliance)
12. [Cost & Budget Issues](#cost--budget-issues)
13. [Multi-Region Scenarios](#multi-region-scenarios)
14. [Disaster Recovery](#disaster-recovery)
15. [Performance Problems](#performance-problems)
16. [Security & Secrets](#security--secrets)
17. [Platform-Specific Issues](#platform-specific-issues)
18. [Advanced Scenarios](#advanced-scenarios)

---

## Authentication & Authorization Issues

### Error: "Please run 'az login' to set up account"

**Cause:** Not logged into Azure CLI

**Solutions:**
```bash
# Solution 1: Interactive login
az login

# Solution 2: Service principal
az login --service-principal \
  --username <app-id> \
  --password <password> \
  --tenant <tenant-id>

# Solution 3: Managed identity (on Azure VM)
az login --identity

# Solution 4: Device code (for remote/headless systems)
az login --use-device-code
```

### Error: "The subscription is disabled"

**Cause:** Azure subscription has been disabled or cancelled

**Solutions:**
1. Check subscription status in Azure Portal
2. Contact billing administrator
3. Switch to different subscription:
   ```bash
   az account list --output table
   az account set --subscription "<subscription-id>"
   ```

### Error: "Multi-factor authentication required"

**Cause:** Conditional access policy requires MFA

**Solutions:**
```bash
# Use device code flow for MFA
az login --use-device-code

# Or use service principal (bypasses MFA)
az login --service-principal --username <app-id> --password <password> --tenant <tenant-id>
```

### Error: "Token expired"

**Cause:** Azure CLI token has expired during long deployment

**Solutions:**
```bash
# Refresh token
az account get-access-token --output none

# Or configure longer token lifetime in deployment script
# Add this to beginning of scripts:
trap 'az account get-access-token --output none' SIGALRM
```

### Error: "Insufficient privileges"

**Cause:** User account lacks required permissions

**Solutions:**
1. Request Owner or Contributor role on subscription
2. Request specific roles:
   - Logic App Contributor
   - Sentinel Contributor
   - Security Admin
3. Use elevated account:
   ```bash
   az logout
   az login --use-device-code --tenant <tenant-id>
   ```

---

## Network & Connectivity Problems

### Error: "Failed to connect to management.azure.com"

**Cause:** Network connectivity issues, proxy, or firewall

**Solutions:**
```bash
# Test connectivity
curl -I https://management.azure.com

# Configure proxy
export HTTP_PROXY=http://proxy.company.com:8080
export HTTPS_PROXY=http://proxy.company.com:8080
az config set proxy.http_proxy=http://proxy.company.com:8080
az config set proxy.https_proxy=http://proxy.company.com:8080

# Bypass SSL verification (NOT recommended for production)
export REQUESTS_CA_BUNDLE=""
```

### Error: "Connection timeout"

**Cause:** Slow network, Azure region issues, or rate limiting

**Solutions:**
```bash
# Increase timeout
export AZURE_HTTP_TIMEOUT=600

# Check Azure status
curl https://status.azure.com/api/v2/status.json | jq

# Try different region
./scripts/deploy-all.sh <rg> <workspace> deployment/parameters.json westus2

# Use retry script
./scripts/deploy-with-retry.sh <rg> <workspace> --max-retries 5
```

### Error: "DNS resolution failed"

**Cause:** DNS issues

**Solutions:**
```bash
# Test DNS
nslookup management.azure.com

# Use alternative DNS
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf

# Check /etc/hosts for conflicts
grep azure /etc/hosts
```

---

## Resource Conflicts & Naming

### Error: "Resource already exists"

**Cause:** Resource with same name already exists

**Solutions:**
```bash
# Check existing resources
az resource list --resource-group <rg> --output table

# Option 1: Delete existing resource
./scripts/rollback.sh delete-logic-apps <rg>

# Option 2: Use different names
# Edit deployment/parameters.json:
{
  "logicAppNamePrefix": {
    "value": "sentinel-v2"
  }
}

# Option 3: Update existing resources
./scripts/deploy-all.sh <rg> <workspace> deployment/parameters.json
# (Will update instead of create)
```

### Error: "Invalid resource name"

**Cause:** Resource name doesn't meet Azure naming requirements

**Solutions:**
```bash
# Valid naming patterns:
# Logic Apps: 1-80 chars, alphanumeric and hyphens
# Resource Groups: 1-90 chars, alphanumeric, underscores, hyphens, periods
# Storage: 3-24 chars, lowercase alphanumeric only

# Fix invalid names in parameters.json
# Bad: "My Logic App!"
# Good: "my-logic-app"

# Validate names before deployment
./scripts/preflight-checks.sh <rg> <workspace>
```

### Error: "Resource lock prevents operation"

**Cause:** Resource or resource group has a lock

**Solutions:**
```bash
# Check for locks
az lock list --resource-group <rg> --output table

# Remove locks (requires Owner permission)
az lock delete --name <lock-name> --resource-group <rg>

# Or request lock removal from administrator
```

---

## Permission & RBAC Errors

### Error: "AuthorizationFailed"

**Cause:** Insufficient permissions for the operation

**Solutions:**
```bash
# Check current role assignments
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --output table

# Request required roles:
# - Contributor (or Owner) on subscription
# - Azure Sentinel Contributor
# - Logic App Contributor
# - Security Admin

# Assign roles (requires Owner permission)
az role assignment create \
  --assignee <user-id> \
  --role "Contributor" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/<rg>"
```

### Error: "Principal does not exist in the directory"

**Cause:** Managed identity not created or propagation delay

**Solutions:**
```bash
# Wait for identity propagation (can take 30-60 seconds)
sleep 60

# Verify identity exists
az ad sp list --filter "displayName eq '<logic-app-name>'" --output table

# Re-run RBAC configuration
./scripts/configure-rbac.sh <rg> <workspace>

# Force identity creation
az resource update \
  --resource-group <rg> \
  --name <logic-app> \
  --resource-type "Microsoft.Logic/workflows" \
  --set identity.type=SystemAssigned
```

### Error: "Role assignment already exists"

**Cause:** Attempting to create duplicate role assignment

**Solutions:**
This is benign - the role is already assigned. Ignore this error or:
```bash
# Check existing assignments
az role assignment list --assignee <principal-id> --output table

# Continue with deployment (script handles this)
```

---

## API Connection Failures

### Error: "Connection 'azuresentinel' is not authenticated"

**Cause:** OAuth connection not authorized

**Solutions:**
```bash
# Run connection setup
./scripts/setup-connections.sh <rg>

# Manual authorization:
# 1. Go to Azure Portal
# 2. Resource Groups > <rg> > Connections
# 3. Click each connection
# 4. Click "Edit API connection"
# 5. Click "Authorize"
# 6. Sign in and consent

# Verify connection status
az resource show \
  --resource-group <rg> \
  --name azuresentinel-connection \
  --resource-type "Microsoft.Web/connections" \
  --query "properties.statuses[0].status"
```

### Error: "Consent required"

**Cause:** Application requires admin consent for permissions

**Solutions:**
```bash
# Option 1: Use admin account
az logout
az login --use-device-code
# Log in with Global Administrator account

# Option 2: Request admin consent
# Send this URL to admin:
# https://login.microsoftonline.com/<tenant-id>/adminconsent?client_id=<app-id>

# Option 3: Pre-consent in Azure AD
# Portal > Azure AD > Enterprise Applications > <app> > Permissions > Grant admin consent
```

### Error: "API connection failed with status 403"

**Cause:** Missing API permissions

**Solutions:**
```bash
# Check API permissions in Azure AD
# Portal > Azure AD > App registrations > <app> > API permissions

# Required permissions:
# - Azure Sentinel: Microsoft.SecurityInsights/read,write
# - Azure AD: Directory.Read.All, User.ReadWrite.All
# - Microsoft Graph: User.ReadWrite.All
# - Office 365: Mail.Send, Mail.ReadWrite

# Grant permissions via script
az ad app permission add \
  --id <app-id> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope
```

---

## Deployment Failures

### Error: "Deployment template validation failed"

**Cause:** Invalid ARM template syntax or parameters

**Solutions:**
```bash
# Validate template locally
az deployment group validate \
  --resource-group <rg> \
  --template-file playbooks/pb-disable-user.json \
  --parameters @deployment/parameters.json

# Check JSON syntax
jq empty playbooks/pb-disable-user.json || echo "Invalid JSON"

# Common issues:
# - Missing required parameters
# - Invalid parameter values
# - Incorrect resource API versions

# Fix parameters
cp deployment/parameters.template.json deployment/parameters.json
nano deployment/parameters.json
```

### Error: "ResourceDeploymentFailure"

**Cause:** Resource failed to deploy

**Solutions:**
```bash
# Get detailed error
az deployment group show \
  --resource-group <rg> \
  --name <deployment-name> \
  --query "properties.error"

# Check deployment operations
az deployment operation group list \
  --resource-group <rg> \
  --name <deployment-name> \
  --query "[?properties.provisioningState=='Failed']" \
  --output table

# Use retry script
./scripts/deploy-with-retry.sh <rg> <workspace> --max-retries 5

# Resume from checkpoint
./scripts/deploy-with-retry.sh <rg> <workspace> --resume
```

### Error: "Deployment exceeded timeout"

**Cause:** Deployment taking too long

**Solutions:**
```bash
# Increase timeout
export AZURE_HTTP_TIMEOUT=1800

# Deploy in smaller batches
# Deploy connections first:
az deployment group create --resource-group <rg> --template-file deployment/api-connections.json

# Then playbooks one by one:
for file in playbooks/*.json; do
  az deployment group create --resource-group <rg> --template-file "$file"
  sleep 10
done

# Use async deployment
az deployment group create --resource-group <rg> --template-file <file> --no-wait
```

---

## Resource Provider Issues

### Error: "The subscription is not registered to use namespace 'Microsoft.Logic'"

**Cause:** Required resource provider not registered

**Solutions:**
```bash
# Register all required providers
az provider register --namespace Microsoft.Logic --wait
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.SecurityInsights --wait
az provider register --namespace Microsoft.OperationsManagement --wait

# Check registration status
az provider show --namespace Microsoft.Logic --query "registrationState"

# Wait for registration (can take 5-10 minutes)
while [ "$(az provider show --namespace Microsoft.Logic --query registrationState -o tsv)" != "Registered" ]; do
  echo "Waiting for registration..."
  sleep 30
done
```

### Error: "Resource provider API version not available"

**Cause:** Using outdated or invalid API version

**Solutions:**
```bash
# Check available API versions
az provider show --namespace Microsoft.Logic --query "resourceTypes[?resourceType=='workflows'].apiVersions[]" --output table

# Update templates with latest version
# In template files, change:
# "apiVersion": "2016-06-01"  # Old
# to:
# "apiVersion": "2019-05-01"  # New
```

---

## Quota & Throttling

### Error: "Quota exceeded for resource type"

**Cause:** Subscription quota limit reached

**Solutions:**
```bash
# Check current usage
az vm list-usage --location eastus --output table

# Request quota increase:
# 1. Portal > Subscriptions > Usage + quotas
# 2. Select resource type
# 3. Click "Request increase"

# Deploy to different region with capacity
./scripts/deploy-all.sh <rg> <workspace> deployment/parameters.json westus2

# Delete unused resources
./scripts/rollback.sh delete-logic-apps <rg>
```

### Error: "Request rate limit exceeded (429)"

**Cause:** Too many API requests in short time

**Solutions:**
```bash
# Use retry script with exponential backoff
./scripts/deploy-with-retry.sh <rg> <workspace> --max-retries 5 --retry-delay 30

# Deploy slower
# Add delays in scripts:
sleep 5  # Between each operation

# Split into smaller batches
# Deploy 5 playbooks at a time instead of all at once

# Check throttling limits
az resource list --resource-group <rg> --query "[].properties.throttling"
```

---

## Data & Format Errors

### Error: "Invalid JSON format"

**Cause:** Malformed JSON files

**Solutions:**
```bash
# Validate all JSON files
./scripts/preflight-checks.sh <rg> <workspace>

# Or manually:
for file in $(find . -name "*.json"); do
  echo "Checking: $file"
  jq empty "$file" || echo "INVALID: $file"
done

# Fix JSON syntax errors
# Common issues:
# - Trailing commas
# - Missing quotes
# - Unclosed brackets
# - Invalid escape sequences

# Use JSON validator
jq . analytics/high_severity_anomalous_signin.json > /tmp/fixed.json
mv /tmp/fixed.json analytics/high_severity_anomalous_signin.json
```

### Error: "Invalid CSV format in watchlist"

**Cause:** CSV file doesn't meet requirements

**Solutions:**
```bash
# Validate CSV files
for file in watchlists/*.csv; do
  head -n 1 "$file" | grep -q "," && echo "OK: $file" || echo "INVALID: $file"
done

# CSV requirements:
# - Must have header row
# - Comma-separated values
# - UTF-8 encoding
# - No special characters in column names

# Fix encoding
iconv -f ISO-8859-1 -t UTF-8 watchlists/high_value_assets.csv > /tmp/fixed.csv
mv /tmp/fixed.csv watchlists/high_value_assets.csv

# Remove invalid characters
sed 's/[^a-zA-Z0-9,_-]//g' watchlists/high_value_assets.csv > /tmp/fixed.csv
```

### Error: "Watchlist size exceeds limit"

**Cause:** CSV file too large (>10MB)

**Solutions:**
```bash
# Check file size
ls -lh watchlists/*.csv

# Split large file
split -l 10000 watchlists/large_file.csv watchlists/split_

# Or store in blob storage and reference
# Upload to Azure Storage, then reference URL in watchlist
```

---

## Version Compatibility

### Error: "Azure CLI version too old"

**Cause:** Using outdated Azure CLI

**Solutions:**
```bash
# Check version
az version

# Update Azure CLI
# macOS:
brew upgrade azure-cli

# Linux:
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Windows:
# Download installer from: https://aka.ms/installazurecliwindows

# Or use Docker
docker run -it mcr.microsoft.com/azure-cli
```

### Error: "Extension 'sentinel' not found"

**Cause:** Sentinel extension not installed

**Solutions:**
```bash
# Install extension
az extension add --name sentinel

# Update extension
az extension update --name sentinel

# List installed extensions
az extension list --output table

# Remove and reinstall if corrupted
az extension remove --name sentinel
az extension add --name sentinel
```

---

## Azure Policy & Compliance

### Error: "Resource disallowed by policy"

**Cause:** Azure Policy blocking deployment

**Solutions:**
```bash
# Check policy assignments
az policy assignment list --query "[].{Name:name, Policy:displayName}" --output table

# Get policy details
az policy state list --query "[?complianceState=='NonCompliant']" --output table

# Options:
# 1. Request policy exemption
az policy exemption create \
  --name "Sentinel-Deployment-Exemption" \
  --policy-assignment <assignment-id> \
  --resource-group <rg> \
  --exemption-category "Waiver"

# 2. Modify deployment to comply with policy
# Example: If policy requires specific tags
# Add to parameters.json:
{
  "tags": {
    "value": {
      "Environment": "Production",
      "CostCenter": "Security",
      "DataClassification": "Confidential"
    }
  }
}

# 3. Deploy to different region without policy
```

### Error: "Location not allowed by policy"

**Cause:** Policy restricts deployment regions

**Solutions:**
```bash
# Check allowed locations
az policy assignment list --query "[?policyDefinitionId contains 'allowedLocations']"

# Deploy to allowed region
./scripts/deploy-all.sh <rg> <workspace> deployment/parameters.json <allowed-region>

# Request policy update to include your region
```

---

## Cost & Budget Issues

### Error: "Spending limit reached"

**Cause:** Azure subscription spending limit reached

**Solutions:**
```bash
# Check spending limit status
az consumption budget list --output table

# Remove spending limit (requires billing admin)
# Portal > Cost Management + Billing > Payment methods > Remove spending limit

# Estimate costs before deploying
./scripts/cost-optimizer.sh estimate <rg> <workspace>

# Set up cost alerts
./scripts/cost-optimizer.sh set-budget <rg> 500 admin@company.com
```

### Error: "Credit card declined"

**Cause:** Payment method issue

**Solutions:**
1. Update payment method in Azure Portal
2. Contact billing support
3. Use different subscription
4. Request PO/invoice billing from Microsoft

---

## Multi-Region Scenarios

### Error: "Region pair unavailable"

**Cause:** Azure region outage affecting both primary and secondary

**Solutions:**
```bash
# Check Azure status
curl https://status.azure.com/api/v2/status.json | jq

# Deploy to alternative region
./scripts/multi-region-deploy.sh deploy-single westeurope <rg> <workspace>

# Failover to different region
./scripts/multi-region-deploy.sh failover eastus westus2 <rg-prefix>
```

### Error: "Cross-region replication failed"

**Cause:** Geo-replication configuration issue

**Solutions:**
```bash
# Check replication status
az monitor log-analytics workspace show \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --query "properties.features.dataReplication"

# Manually sync configuration
./scripts/multi-region-deploy.sh sync <source-rg> <target-rg>

# Re-deploy to secondary region
./scripts/deploy-all.sh <secondary-rg> <secondary-workspace> deployment/parameters.json <secondary-region>
```

---

## Disaster Recovery

### Error: "Primary region completely unavailable"

**Cause:** Regional Azure outage

**Solutions:**
```bash
# Immediate actions:
# 1. Check Azure status
curl https://status.azure.com/api/v2/status.json

# 2. Failover to secondary region
./scripts/multi-region-deploy.sh failover eastus westus2 rg-sentinel

# 3. Update DNS/Traffic Manager
az network traffic-manager endpoint update \
  --name endpoint-eastus \
  --profile-name sentinel-tm-profile \
  --resource-group rg-sentinel \
  --type azureEndpoints \
  --endpoint-status Disabled

# 4. Notify team
# 5. Document incident

# Recovery:
# 1. Wait for region restoration
# 2. Sync configuration from secondary
./scripts/multi-region-deploy.sh sync rg-sentinel-westus2 rg-sentinel-eastus

# 3. Validate primary region
./scripts/validate-deployment.sh rg-sentinel-eastus sentinel-workspace-eastus

# 4. Failback
./scripts/multi-region-deploy.sh failover westus2 eastus rg-sentinel
```

### Error: "Backup corrupted or missing"

**Cause:** Backup files deleted or corrupted

**Solutions:**
```bash
# List available backups
./scripts/rollback.sh list-backups

# Export current state as backup
./scripts/migrate-upgrade.sh export <rg> ./emergency-backup

# Restore from Git history
git log --all --full-history -- "*.json"
git checkout <commit-hash> -- playbooks/

# Reconstruct from Azure
./scripts/migrate-upgrade.sh export <rg> ./reconstructed-backup
```

---

## Performance Problems

### Error: "Logic App execution taking too long"

**Cause:** Performance issues in workflow

**Solutions:**
```bash
# Check run history
./scripts/health-monitor.sh run-history <rg> <workspace> <logic-app-name>

# Identify slow actions
az rest --method GET \
  --uri "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/<app>/runs/<run-id>?api-version=2019-05-01" \
  --query "properties.response.startTime,properties.response.endTime,actions[].{name:name,duration:duration}"

# Optimize:
# 1. Add parallel branches
# 2. Reduce API calls
# 3. Use pagination for large datasets
# 4. Cache frequently accessed data
# 5. Increase timeout values
```

### Error: "Workspace query timeout"

**Cause:** Complex KQL query taking too long

**Solutions:**
```bash
# Optimize KQL queries:
# - Add time filters: | where TimeGenerated > ago(1h)
# - Limit results: | take 1000
# - Use summarize: | summarize count() by ColumnName
# - Avoid wildcards at start: SecurityEvent | where * contains "pattern"

# Increase query timeout
az monitor log-analytics query \
  --workspace <workspace> \
  --analytics-query "<query>" \
  --timespan P1D \
  --timeout 600

# Use workspace insights to identify slow queries
az monitor log-analytics workspace show \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --query "properties.features.slowQueryThreshold"
```

---

## Security & Secrets

### Error: "Secret detected in repository"

**Cause:** Accidentally committed secrets to Git

**Solutions:**
```bash
# Immediately rotate exposed secrets
./scripts/secrets-manager.sh rotate <keyvault> teams-webhook-url "<new-value>"

# Remove from Git history
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch deployment/parameters.json" \
  --prune-empty --tag-name-filter cat -- --all

# Or use BFG Repo-Cleaner
bfg --replace-text passwords.txt

# Move secrets to Key Vault
./scripts/secrets-manager.sh setup <rg> <keyvault-name> <location>

# Scan for secrets
./scripts/secrets-manager.sh scan
```

### Error: "Key Vault access denied"

**Cause:** Missing Key Vault permissions

**Solutions:**
```bash
# Grant access to user
az keyvault set-policy \
  --name <keyvault> \
  --upn user@company.com \
  --secret-permissions get list set

# Grant access to Logic App managed identity
PRINCIPAL_ID=$(az resource show --resource-group <rg> --name <logic-app> --resource-type "Microsoft.Logic/workflows" --query "identity.principalId" -o tsv)

az keyvault set-policy \
  --name <keyvault> \
  --object-id $PRINCIPAL_ID \
  --secret-permissions get list
```

---

## Platform-Specific Issues

### macOS Issues

```bash
# Issue: "sed: illegal option"
# Cause: macOS uses BSD sed
# Solution: Install GNU sed
brew install gnu-sed
export PATH="/usr/local/opt/gnu-sed/libexec/gnubin:$PATH"

# Issue: "date: illegal option -v"
# Cause: Different date syntax
# Solution: Install coreutils
brew install coreutils
alias date=gdate

# Issue: Azure CLI install fails
# Solution: Use pip
pip3 install --user azure-cli
```

### Windows/WSL Issues

```bash
# Issue: "line endings LF vs CRLF"
# Solution: Convert line endings
dos2unix scripts/*.sh

# Issue: Permission denied executing script
# Solution: Add execute permission
chmod +x scripts/*.sh

# Issue: "/usr/bin/env: 'bash\r': No such file"
# Solution: Remove Windows line endings
sed -i 's/\r$//' scripts/deploy-all.sh
```

### Linux Distribution Specific

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y jq curl azure-cli

# CentOS/RHEL
sudo yum install -y jq curl
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo yum install -y azure-cli

# Alpine
apk add --no-cache bash jq curl
pip install azure-cli
```

---

## Advanced Scenarios

### Scenario: Corporate Proxy with SSL Inspection

```bash
# Configure proxy
export HTTP_PROXY=http://proxy.corp.com:8080
export HTTPS_PROXY=http://proxy.corp.com:8080
export NO_PROXY=localhost,127.0.0.1

# Import corporate CA certificate
curl http://proxy.corp.com/ca.crt -o /usr/local/share/ca-certificates/corp-ca.crt
update-ca-certificates

# Configure Azure CLI
az config set proxy.http_proxy=http://proxy.corp.com:8080
az config set proxy.https_proxy=http://proxy.corp.com:8080
```

### Scenario: Air-Gapped Environment

```bash
# Option 1: Use Azure Stack Hub
# Deploy to on-premises Azure Stack

# Option 2: Download packages offline
# On internet-connected machine:
az extension add --name sentinel --output-folder /tmp/extensions

# Transfer /tmp/extensions to air-gapped machine
# On air-gapped machine:
az extension add --source /tmp/extensions/sentinel-*.whl

# Option 3: Use Azure Arc
# Connect on-premises resources to Azure
```

### Scenario: Multi-Tenant Deployment

```bash
# Deploy to multiple tenants
for tenant in tenant1 tenant2 tenant3; do
  az login --tenant ${tenant}-tenant-id
  ./scripts/deploy-all.sh rg-${tenant} workspace-${tenant} deployment/parameters-${tenant}.json
done

# Use managed identities for cross-tenant access
az ad sp create-for-rbac --name "SentinelDeployment-${tenant}"
```

### Scenario: Hybrid Cloud (Azure + AWS/GCP)

```bash
# Integrate AWS GuardDuty
# 1. Deploy connector in AWS
# 2. Configure data export to Azure Event Hub
# 3. Ingest into Sentinel workspace

# Integrate GCP Security Command Center
# 1. Configure Pub/Sub topic
# 2. Deploy Azure Function to consume messages
# 3. Forward to Sentinel
```

---

## Emergency Procedures

### Complete Rollback

```bash
# 1. Create backup immediately
./scripts/rollback.sh backup <rg>

# 2. Delete all deployed resources
./scripts/rollback.sh delete-all <rg> <workspace> --force

# 3. Verify clean state
az resource list --resource-group <rg>

# 4. Re-deploy from known good state
git checkout <stable-commit>
./scripts/deploy-all.sh <rg> <workspace> deployment/parameters.json
```

### Recovery from Partial Deployment

```bash
# Check what's deployed
./scripts/validate-deployment.sh <rg> <workspace>

# Resume from last checkpoint
./scripts/deploy-with-retry.sh <rg> <workspace> --resume

# Or start fresh with state reset
./scripts/deploy-with-retry.sh <rg> <workspace> --reset-state
```

### Data Loss Prevention

```bash
# Before any destructive operation:
# 1. Backup configuration
./scripts/migrate-upgrade.sh export <rg> ./pre-change-backup

# 2. Backup secrets
./scripts/secrets-manager.sh backup <keyvault> ./secrets-backup.json.enc

# 3. Export watchlists
for wl in $(az sentinel watchlist list --resource-group <rg> --workspace-name <workspace> --query "[].watchlistAlias" -o tsv); do
  az sentinel watchlist show --resource-group <rg> --workspace-name <workspace> --watchlist-alias $wl > ./backups/${wl}.json
done

# 4. Document current state
./scripts/health-monitor.sh generate-report <rg> <workspace> ./pre-change-report.html
```

---

## Getting Help

If none of these solutions work:

1. **Check logs:**
   ```bash
   # Azure CLI debug mode
   az deployment group create --debug ...
   
   # Detailed error
   az deployment group show --resource-group <rg> --name <deployment> --query "properties.error"
   ```

2. **Run diagnostics:**
   ```bash
   ./scripts/preflight-checks.sh <rg> <workspace>
   ./scripts/validate-deployment.sh <rg> <workspace>
   ./scripts/health-monitor.sh check-all <rg> <workspace>
   ```

3. **Collect support information:**
   ```bash
   az version > support-info.txt
   az account show >> support-info.txt
   az resource list --resource-group <rg> >> support-info.txt
   ```

4. **Contact support:**
   - GitHub Issues: https://github.com/uakbr/sentinel-content-pack/issues
   - Email: umair@tesla.com.ai
   - Azure Support: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade

5. **Community resources:**
   - Stack Overflow: Tag `azure-sentinel`
   - Microsoft Q&A: https://docs.microsoft.com/answers/
   - Tech Community: https://techcommunity.microsoft.com/

