#!/bin/bash

set -euo pipefail

# Initialize INITJSON variable
INITJSON="init.json"

# Ensure the init.json file exists
if [[ ! -f "$INITJSON" ]]; then
  echo "Error: $INITJSON file not found. Exiting."
  exit 1
fi

# Constants
DEPLOYED=$(jq -r '.DEPLOYED' "$INITJSON")
PROJECT_NAME=$(jq -r '.PROJECT_NAME' "$INITJSON")
LOCATION=$(jq -r '.LOCATION' "$INITJSON")
readarray -t CONTENTREPOS < <(jq -r '.REPOS[]' "$INITJSON")

# Check if variables were properly initialized
if [[ -z "$DEPLOYED" || -z "$PROJECT_NAME" || -z "$LOCATION" || ${#CONTENTREPOS[@]} -eq 0 ]]; then
  echo "Error: Failed to initialize variables from $INITJSON. Exiting."
  exit 1
fi

MAX_RETRIES=2
RETRY_DELAY=10

# Extract GitHub organization and control repo
GITHUB_ORG=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')
CONTROL_REPO=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)\.git#\1#p')

if [[ -z "$GITHUB_ORG" ]]; then
  echo "Could not detect GitHub organization. Exiting."
  exit 1
fi

# Function to ensure the user is authenticated to GitHub
ensure_github_login() {
  if ! gh auth status &>/dev/null; then
    gh auth login || {
      echo "GitHub login failed. Exiting."
      exit 1
    }
  fi
}

prompt_for_PAT(){
  read -rp "Enter GitHub PAT: " PAT
}

# Function to check if a GitHub repository exists
repo_exists() {
  local repo=$1
  gh repo view "${GITHUB_ORG}/${repo}" &>/dev/null
}

# Function to create a GitHub repository
create_github_repo() {
  local repo=$1
  gh repo create "${GITHUB_ORG}/${repo}" --private
}

# Function to check and create repositories if needed
check_and_create_repos() {
  for repo in "${CONTENTREPOS[@]}"; do
    if ! repo_exists "$repo"; then
      read -rp "Create repository '$repo' in organization '$GITHUB_ORG'? (y/n)" create_repo
      if [[ "$create_repo" =~ ^[Yy]$ ]]; then
        create_github_repo "$repo"
      else
        echo "Repository creation aborted. Exiting."
        exit 1
      fi
    fi
  done
}

# Function to log in to Azure if not already logged in
ensure_azure_login() {
  if ! az account show &>/dev/null; then
    az login --use-device-code
  fi
}

# Function to select Azure subscription
select_subscription() {
  local current_sub_name current_sub_id confirm subscription_name subscription_id

  current_sub_name=$(az account show --query "name" --output tsv 2>/dev/null)
  current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

  if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
    echo "Failed to retrieve current subscription. Ensure you are logged in to Azure."
    exit 1
  fi

  read -rp "Use the current default subscription: $current_sub_name (ID: $current_sub_id) (y/n)? " confirm

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    SUBSCRIPTION_ID="$current_sub_id"
  else
    az account list --query '[].{Name:name, ID:id}' --output table
    read -rp "Enter the name of the subscription you want to set as default: " subscription_name
    SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
      echo "Invalid subscription name. Exiting."
      exit 1
    fi
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
}

generate_ssh_keys() {
  for repo in "${CONTENTREPOS[@]}"; do
    local key_path="$HOME/.ssh/id_ed25519-$repo"
    if [[ -f "$key_path" ]]; then
      read -rp "$key_path already exists. Overwrite (y/n)? " overwrite_key
      if [[ "$overwrite_key" =~ ^[Yy]$ ]]; then
        ssh-keygen -t ed25519 -N "" -f "$key_path" -q
      else
        echo "Using existing key for $repo"
      fi
    else
      ssh-keygen -t ed25519 -N "" -f "$key_path" -q
    fi
  done
}

create_azure_resources() {
  # Check if resource group exists
  if ! az group show -n "${PROJECT_NAME}-tfstate-RG" &>/dev/null; then
    az group create -n "${PROJECT_NAME}-tfstate-RG" -l "${LOCATION}"
  fi

  # Check if storage account exists
  if ! az storage account show -n "${PROJECT_NAME}account" -g "${PROJECT_NAME}-tfstate-RG" &>/dev/null; then
    az storage account create -n "${PROJECT_NAME}account" -g "${PROJECT_NAME}-tfstate-RG" -l "${LOCATION}" --sku Standard_LRS
  fi

  # Check if storage container exists
  if ! az storage container show -n "${PROJECT_NAME}tfstate" --account-name "${PROJECT_NAME}account" &>/dev/null; then
    az storage container create -n "${PROJECT_NAME}tfstate" --account-name "${PROJECT_NAME}account" --auth-mode login
  fi
}

# Function to create or use an existing service principal and assign roles
create_service_principal() {
  local sp_output

  # Create or get existing service principal
  sp_output=$(az ad sp create-for-rbac --name "${PROJECT_NAME}" --role Contributor --scopes "/subscriptions/${1}" --sdk-auth --only-show-errors)
  clientId=$(echo "$sp_output" | jq -r .clientId)
  tenantId=$(echo "$sp_output" | jq -r .tenantId)
  clientSecret=$(echo "$sp_output" | jq -r .clientSecret)
  subscriptionId=$(echo "$sp_output" | jq -r .subscriptionId)
  AZURE_CREDENTIALS=$(echo "$sp_output" | jq -c '{clientId, clientSecret, subscriptionId, tenantId, resourceManagerEndpointUrl}')
  echo $AZURE_CREDENTIALS

  if [[ -z "$clientId" || "$clientId" == "null" ]]; then
    echo "Error: Failed to retrieve or create the service principal. Exiting."
    exit 1
  fi

  # Check if role assignment already exists
  role_exists=$(az role assignment list --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" --query '[].id' -o tsv)

  if [[ ! -n "$role_exists" ]]; then
    # Create role assignment if it doesn't exist
    az role assignment create --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" || {
      echo "Failed to assign the role. Exiting."
      exit 1
    }
  fi
}

# Function to create GitHub secrets
create_github_secrets() {
  local secret_key

  gh secret set AZURE_STORAGE_ACCOUNT_NAME -b "${PROJECT_NAME}account"
  gh secret set TFSTATE_CONTAINER_NAME -b "${PROJECT_NAME}tfstate"
  gh secret set AZURE_RESOURCE_GROUP_NAME -b "${PROJECT_NAME}-tfstate-RG"
  gh secret set ARM_SUBSCRIPTION_ID -b "${subscriptionId}"
  gh secret set ARM_TENANT_ID -b "${tenantId}"
  gh secret set ARM_CLIENT_ID -b "${clientId}"
  gh secret set ARM_CLIENT_SECRET -b "${clientSecret}"
  gh secret set AZURE_CREDENTIALS -b "${AZURE_CREDENTIALS}"
  gh secret set ACR_REGISTRY -b "${PROJECT_NAME}.azurecr.io"
  gh secret set PROJECTNAME -b "${PROJECT_NAME}"
  gh secret set LOCATION -b "${LOCATION}"
  gh secret set PAT -b "$PAT"
  gh variable set DEPLOYED -b "$DEPLOYED"

  for repo in "${CONTENTREPOS[@]}"; do
    gh secret set PAT -b "$PAT" --repo ${GITHUB_ORG}/$repo
  done
  
  for repo in "${CONTENTREPOS[@]}"; do
    secret_key=$(cat $HOME/.ssh/id_ed25519-$repo)
    gh secret set ${repo^^}_SSH_PRIVATE_KEY -b "$secret_key"
  done
  
}

# Function to handle deploy keys for repositories
handle_deploy_keys() {
  for repo in "${CONTENTREPOS[@]}"; do
    # Get the deploy key ID if it exists
    deploy_key_id=$(gh repo deploy-key list --repo ${GITHUB_ORG}/$repo --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')

    # Check if the deploy key exists and delete it if necessary
    if [[ -n "$deploy_key_id" ]]; then
      gh repo deploy-key delete --repo ${GITHUB_ORG}/$repo "$deploy_key_id"
    fi
    gh repo deploy-key add $HOME/.ssh/id_ed25519-${repo}.pub --title 'DEPLOY-KEY' --repo ${GITHUB_ORG}/$repo
  done
}

# Main execution flow
ensure_azure_login
ensure_github_login
prompt_for_PAT
select_subscription
create_azure_resources
create_service_principal "$SUBSCRIPTION_ID"
generate_ssh_keys
check_and_create_repos
create_github_secrets
handle_deploy_keys
gh workflow run docs-builder
