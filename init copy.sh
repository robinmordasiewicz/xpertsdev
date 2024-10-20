#!/bin/bash

# Ensure the contentrepos.json file exists
if [ ! -f contentrepos.json ]; then
  echo "Error: contentrepos.json file not found. Exiting."
  exit 1
fi

# Constants
DEPLOYED=$(jq -r '.DEPLOYED' contentrepos.json)
PROJECT_NAME=$(jq -r '.PROJECT_NAME' contentrepos.json)
LOCATION=$(jq -r '.LOCATION' contentrepos.json)
CONTENTREPOS=($(jq -r '.REPOS[]' contentrepos.json))

# Check if variables were properly initialized
if [ -z "$DEPLOYED" ] || [ -z "$PROJECT_NAME" ] || [ -z "$LOCATION" ] || [ ${#CONTENTREPOS[@]} -eq 0 ]; then
  echo "Error: Failed to initialize variables from contentrepos.json. Exiting."
  exit 1
fi

MAX_RETRIES=2
RETRY_DELAY=10

# Extract GitHub organization and control repo
GITHUB_ORG=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')
CONTROL_REPO=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)\.git#\1#p')

if [ -z "$GITHUB_ORG" ]; then
  echo "Could not detect GitHub organization. Exiting."
  exit 1
fi

# Function to ensure the user is authenticated to GitHub
function ensure_github_login() {
  gh auth status &>/dev/null
  if [ $? -ne 0 ]; then
    gh auth login
    if [ $? -ne 0 ]; then
      echo "GitHub login failed. Exiting."
      exit 1
    fi
  fi
}

# Function to check if a GitHub repository exists
function repo_exists() {
  local repo=$1
  gh repo view "${GITHUB_ORG}/${repo}" &>/dev/null
  return $?
}

# Function to create a GitHub repository
function create_github_repo() {
  local repo=$1
  gh_command_retry "gh repo create ${GITHUB_ORG}/${repo} --private"
}

# Function to retry GitHub commands with a retry mechanism, suppressing errors until max retries
function gh_command_retry() {
  local cmd=$1
  local retries=0
  local output

  until [ $retries -ge $MAX_RETRIES ]; do
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
      return 0
    elif [ $exit_code -ge 500 ]; then
      echo "Server-side error (5xx). Retrying in $RETRY_DELAY seconds..."
    else
      echo "GitHub command failed. Retrying in $RETRY_DELAY seconds..."
    fi
    
    retries=$((retries + 1))
    sleep $RETRY_DELAY
  done

  echo "GitHub command failed after $MAX_RETRIES attempts."
  echo "Error output from the last attempt:"
  echo "$output"
  exit 1
}

# Function to check and create repositories if needed
function check_and_create_repos() {
  for repo in "${CONTENTREPOS[@]}"; do
    if ! repo_exists "$repo"; then
      echo "Repository '$repo' does not exist in organization '$GITHUB_ORG'."
      read -p "Do you want to create this repository? (y/n): " create_repo
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
function ensure_azure_login() {
  az account show &>/dev/null
  if [ $? -ne 0 ]; then
    az login --use-device-code
  fi
}

# Function to select Azure subscription
function select_subscription() {
  local current_sub_name current_sub_id confirm subscription_name subscription_id

  current_sub_name=$(az account show --query "name" --output tsv 2>/dev/null)
  current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

  if [ -z "$current_sub_name" ] || [ -z "$current_sub_id" ]; then
    echo "Failed to retrieve current subscription. Ensure you are logged in to Azure."
    exit 1
  fi

  echo "Current default subscription: $current_sub_name (ID: $current_sub_id)"
  read -p "Do you want to use this subscription as default (y/n)? " confirm

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    SUBSCRIPTION_ID="$current_sub_id"
  else
    az account list --query '[].{Name:name, ID:id}' --output table
    read -p "Enter the name of the subscription you want to set as default: " subscription_name
    SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
    if [ -z "$SUBSCRIPTION_ID" ]; then
      echo "Invalid subscription name. Exiting."
      exit 1
    fi
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
}

# Function to create SSH keys for repositories if they don't already exist
function generate_ssh_keys() {
  for repo in "${CONTENTREPOS[@]}"; do
    local key_path="$HOME/.ssh/id_ed25519-$repo"
    if [ ! -f "$key_path" ]; then
      ssh-keygen -t ed25519 -N '' -f "$key_path" -q
      echo "SSH key generated for $repo."
    else
      echo "SSH key already exists for $repo. Skipping generation."
    fi
  done
}

# Function to create Azure resources for Terraform state storage
function create_azure_resources() {
  az group create -n "${PROJECT_NAME}-tfstate-RG" -l ${LOCATION}
  az storage account create -n "${PROJECT_NAME}account" -g "${PROJECT_NAME}-tfstate-RG" -l ${LOCATION} --sku Standard_LRS
  az storage container create -n "${PROJECT_NAME}tfstate" --account-name "${PROJECT_NAME}account" --auth-mode login
}

# Function to create or use an existing service principal and assign roles
function create_service_principal() {
  az ad sp create-for-rbac --name ${PROJECT_NAME} --role Contributor --scopes "/subscriptions/${1}" --json-auth > creds.json
  sp_output=$(cat creds.json)
  echo "Service Principal Output:"
  echo "$sp_output"

  if echo "$sp_output" | grep -q "Found an existing application instance"; then
    echo "Service principal already exists. Proceeding to fetch client ID."
    client_id=$(az ad sp list --display-name ${PROJECT_NAME} --query "[0].appId" --output tsv)
    if [ -z "$client_id" ]; then
      echo "Error: Failed to retrieve the client ID of the existing service principal. Exiting."
      exit 1
    fi
  else
    client_id=$(echo "$sp_output" | jq -r .clientId)
  fi

  if [ -z "$client_id" ] || [ "$client_id" == "null" ]; then
    echo "Error: Failed to retrieve or create the service principal. Exiting."
    exit 1
  fi
  
  az role assignment create --assignee "$client_id" --role "User Access Administrator" --scope "/subscriptions/$1"
  if [ $? -ne 0 ]; then
    echo "Failed to assign the role. Exiting."
    exit 1
  fi
}

# Function to create GitHub secrets with retry
function create_github_secrets() {
  local secret_key

  gh_command_retry "gh secret set AZURE_STORAGE_ACCOUNT_NAME -b '${PROJECT_NAME}account'"
  gh_command_retry "gh secret set TFSTATE_CONTAINER_NAME -b '${PROJECT_NAME}tfstate'"
  gh_command_retry "gh secret set AZURE_RESOURCE_GROUP_NAME -b '${PROJECT_NAME}-tfstate-RG'"
  gh_command_retry "gh secret set ARM_SUBSCRIPTION_ID -b '$(jq -r .subscriptionId creds.json)'"
  gh_command_retry "gh secret set ARM_TENANT_ID -b '$(jq -r .tenantId creds.json)'"
  gh_command_retry "gh secret set ARM_CLIENT_ID -b '$(jq -r .clientId creds.json)'"
  gh_command_retry "gh secret set ARM_CLIENT_SECRET -b '$(jq -r .clientSecret creds.json)'"
  gh_command_retry "gh secret set AZURE_CREDENTIALS -b '$(jq -c . creds.json)'"
  gh_command_retry "gh secret set ACR_REGISTRY -b '${PROJECT_NAME}.azurecr.io'"
  gh_command_retry "gh secret set PROJECTNAME -b '${PROJECT_NAME}'"
  gh_command_retry "gh secret set LOCATION -b '${LOCATION}'"

  read -p "Enter GitHub PAT: " PAT
  for repo in "${CONTENTREPOS[@]}"; do
    gh_command_retry "gh secret set PAT -b '$PAT' --repo '${GITHUB_ORG}/$repo'"
  done
  gh_command_retry "gh secret set PAT -b '$PAT' --repo '${GITHUB_ORG}/${CONTROL_REPO}'"

  for repo in "${CONTENTREPOS[@]}"; do
    secret_key=$(cat $HOME/.ssh/id_ed25519-"$repo")
    gh_command_retry "gh secret set '${repo^^}_SSH_PRIVATE_KEY' -b '$secret_key'"
  done

  gh_command_retry "gh variable set DEPLOYED -b '$DEPLOYED'"
}

# Function to handle deploy keys for repositories
function handle_deploy_keys() {
  for repo in "${CONTENTREPOS[@]}"; do
    # Get the deploy key ID if it exists
    deploy_key_id=$(gh repo deploy-key list --repo "${GITHUB_ORG}/$repo" --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')

    # Check if the deploy key exists and delete it if necessary
    if [ -n "$deploy_key_id" ]; then
      echo "Deploy key found for '$repo'. Deleting the existing key."
      gh_command_retry "gh repo deploy-key delete --repo '${GITHUB_ORG}/$repo' '$deploy_key_id'"
    fi

    # Add the new deploy key
    echo "Adding new deploy key for '$repo'."
    gh_command_retry "gh repo deploy-key add $HOME/.ssh/id_ed25519-'$repo'.pub --title 'DEPLOY-KEY' --repo '${GITHUB_ORG}/$repo'"
  done
}

# Main execution flow

ensure_azure_login
select_subscription
create_service_principal "$SUBSCRIPTION_ID"
create_azure_resources
generate_ssh_keys
ensure_github_login
check_and_create_repos
create_github_secrets
handle_deploy_keys
gh_command_retry "gh workflow run docs-builder"
