#!/bin/bash
#

DEPLOYED="true"
PROJECTNAME="xpertshandsonlabs"
LOCATION="eastus"

ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-docs
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-theme
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-cloud
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-ot
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-sase
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-secops
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519-references

# Log in to Azure if not already logged in
az account show &> /dev/null
if [ $? -ne 0 ]; then
  echo "You are not logged in to Azure. Logging in..."
  az login --use-device-code
fi

# Fetch and display the current default subscription
CURRENT_SUBSCRIPTION_NAME=$(az account show --query "name" --output tsv)
CURRENT_SUBSCRIPTION_ID=$(az account show --query "id" --output tsv)

echo "Current default subscription is: $CURRENT_SUBSCRIPTION_NAME (ID: $CURRENT_SUBSCRIPTION_ID)"

# Prompt the user to confirm if they want to use the current default subscription
read -p "Do you want to use this subscription as default (y/n)? " CONFIRM

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  SUBSCRIPTIONID=$CURRENT_SUBSCRIPTION_ID
else
  # List available subscriptions
  echo "Fetching available subscriptions..."
  az account list --query '[].{Name:name, ID:id}' --output table

  # Prompt user to select a new default subscription by name
  read -p "Enter the name of the subscription you want to set as default: " SUBSCRIPTION_NAME

  # Set the new default subscription and store its ID
  SUBSCRIPTIONID=$(az account list --query "[?name=='$SUBSCRIPTION_NAME'].id" --output tsv)

  if [ -z "$SUBSCRIPTIONID" ]; then
    echo "Invalid subscription name. Exiting."
    exit 1
  fi

  # Set the subscription as default
  az account set --subscription "$SUBSCRIPTIONID"

  echo "Subscription '$SUBSCRIPTION_NAME' is now set as the default with ID: $SUBSCRIPTIONID"
fi

echo "Using Subscription ID: $SUBSCRIPTIONID"

gh auth login

USERNAME=$(az ad signed-in-user show -o json | jq -r '.mail | split("@")[0]')

# Create an Azure Resource group to store the Terraform state.
az group create -n "${PROJECTNAME}-tfstate-RG" -l ${LOCATION}
az storage account create -n "${PROJECTNAME}account" -g "${PROJECTNAME}-tfstate-RG" -l ${LOCATION} --sku Standard_LRS
az storage container create -n "${PROJECTNAME}tfstate" --account-name "${PROJECTNAME}account" --auth-mode login

# Create a service principal
#az ad sp create-for-rbac --name ${PROJECTNAME} --role Contributor --role acrpush --scopes "/subscriptions/${SUBSCRIPTIONID}" --json-auth > creds.json
az ad sp create-for-rbac --name ${PROJECTNAME} --role Contributor --scopes "/subscriptions/${SUBSCRIPTIONID}" --json-auth > creds.json
az role assignment create --assignee "$(jq -r .clientId creds.json)" --role "User Access Administrator" --scope "/subscriptions/${SUBSCRIPTIONID}"
#az role assignment create --scope "/subscriptions/${SUBSCRIPTIONID}" --role acrpull --assignee "$(jq -r .clientId creds.json)"

# Create GitHub secrets.
gh secret set AZURE_STORAGE_ACCOUNT_NAME -b "${PROJECTNAME}account"
sleep 10
gh secret set TFSTATE_CONTAINER_NAME -b "${PROJECTNAME}tfstate"
sleep 10
gh secret set AZURE_RESOURCE_GROUP_NAME -b "${PROJECTNAME}-tfstate-RG"
sleep 10
gh secret set ARM_SUBSCRIPTION_ID -b "$(jq -r .subscriptionId creds.json)"
sleep 10
gh secret set ARM_TENANT_ID -b "$(jq -r .tenantId creds.json)"
sleep 10
gh secret set ARM_CLIENT_ID -b "$(jq -r .clientId creds.json)"
sleep 10
gh secret set ARM_CLIENT_SECRET -b "$(jq -r .clientSecret creds.json)"
sleep 10
gh secret set AZURE_CREDENTIALS -b "$(jq -c . creds.json)"
sleep 10
gh secret set ACR_REGISTRY -b "${PROJECTNAME}.azurecr.io"
sleep 10
gh secret set PROJECTNAME -b "${PROJECTNAME}"
sleep 10
gh secret set LOCATION -b "${LOCATION}"
sleep 10
read -p "enter github PAT" PAT
gh secret set PAT -b "${PAT}" --repo amerintlxperts/theme
sleep 10
gh secret set PAT -b "${PAT}" --repo amerintlxperts/cloud
sleep 10
gh secret set PAT -b "${PAT}" --repo amerintlxperts/ot
sleep 10
gh secret set PAT -b "${PAT}" --repo amerintlxperts/secops
sleep 10
gh secret set PAT -b "${PAT}" --repo amerintlxperts/sase
sleep 10
gh secret set PAT -b "${PAT}" --repo amerintlxperts/references
sleep 10
gh secret set PAT -b "${PAT}" --repo amerintlxperts/.github
sleep 10

KEY=$(cat ~/.ssh/id_ed25519-theme)
gh secret set THEME_SSH_PRIVATE_KEY -b "${KEY}"
sleep 10

KEY=$(cat ~/.ssh/id_ed25519-sase)
gh secret set SASE_SSH_PRIVATE_KEY -b "${KEY}"
sleep 10

KEY=$(cat ~/.ssh/id_ed25519-ot)
gh secret set OT_SSH_PRIVATE_KEY -b "${KEY}"
sleep 10

KEY=$(cat ~/.ssh/id_ed25519-cloud)
gh secret set CLOUD_SSH_PRIVATE_KEY -b "${KEY}"
sleep 10

KEY=$(cat ~/.ssh/id_ed25519-secops)
gh secret set SECOPS_SSH_PRIVATE_KEY -b "${KEY}"
sleep 10

KEY=$(cat ~/.ssh/id_ed25519-references)
gh secret set REFERENCES_SSH_PRIVATE_KEY -b "${KEY}"
sleep 10

gh variable set DEPLOYED -b "${DEPLOYED}"
sleep 10

echo "Enter the documentation password"
gh secret set HTPASSWD
sleep 10

gh repo deploy-key delete $(gh repo deploy-key list --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-docs.pub --title "DEPLOY-KEY"
sleep 10

gh repo deploy-key delete --repo amerintlxperts/theme $(gh repo deploy-key list --repo amerintlxperts/theme --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-theme.pub --title "DEPLOY-KEY" --repo amerintlxperts/theme
sleep 10

gh repo deploy-key delete --repo amerintlxperts/ot $(gh repo deploy-key list --repo amerintlxperts/ot --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-ot.pub --title "DEPLOY-KEY" --repo amerintlxperts/ot
sleep 10

gh repo deploy-key delete --repo amerintlxperts/cloud $(gh repo deploy-key list --repo amerintlxperts/cloud --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-cloud.pub --title "DEPLOY-KEY" --repo amerintlxperts/cloud
sleep 10

gh repo deploy-key delete --repo amerintlxperts/sase $(gh repo deploy-key list --repo amerintlxperts/sase --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-sase.pub --title "DEPLOY-KEY" --repo amerintlxperts/sase
sleep 10

gh repo deploy-key delete --repo amerintlxperts/secops $(gh repo deploy-key list --repo amerintlxperts/secops --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-secops.pub --title "DEPLOY-KEY" --repo amerintlxperts/secops
sleep 10

gh repo deploy-key delete --repo amerintlxperts/references $(gh repo deploy-key list --repo amerintlxperts/references --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
sleep 10
gh repo deploy-key add ~/.ssh/id_ed25519-references.pub --title "DEPLOY-KEY" --repo amerintlxperts/references
sleep 10

gh workflow run docs-builder
