#!/bin/bash

set -euo pipefail

# Initialize INITJSON variable
INITJSON="config.json"

# Ensure the init.json file exists
if [[ ! -f "$INITJSON" ]]; then
  echo "Error: $INITJSON file not found. Exiting."
  exit 1
fi

# Constants
DEPLOYED=$(jq -r '.DEPLOYED' "$INITJSON")
PROJECT_NAME=$(jq -r '.PROJECT_NAME' "$INITJSON")
LOCATION=$(jq -r '.LOCATION' "$INITJSON")
THEME_REPO_NAME=$(jq -r '.THEME_REPO_NAME' "$INITJSON")
readarray -t CONTENTREPOS < <(jq -r '.REPOS[]' "$INITJSON")
CONTENTREPOS+=("$THEME_REPO_NAME")

current_dir=$(pwd)

# Check if variables were properly initialized
if [[ -z "$DEPLOYED" || -z "$PROJECT_NAME" || -z "$LOCATION" || ${#CONTENTREPOS[@]} -eq 0 ]]; then
  echo "Error: Failed to initialize variables from $INITJSON. Exiting."
  exit 1
fi

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

function clone_and_init_repo() {
  # Use a trap to ensure that temporary directories are cleaned up safely
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  local github_token="$PAT"
  local file="dispatch.yml"

  # Check if dispatch.yml file exists before proceeding
  if [[ ! -f "$file" ]]; then
    echo "Error: File $file not found. Please ensure it is present in the current directory."
    exit 1
  fi

  for repo in "${CONTENTREPOS[@]}"; do
    # Return to the original working directory at the start of each loop iteration
    cd "$TEMP_DIR" || exit 1

    # Clone the private repository using the GITHUB_TOKEN
    if ! git clone "https://$github_token@github.com/${GITHUB_ORG}/$repo"; then
      echo "Error: Failed to clone repository $repo"
      continue
    fi

    cd "$repo" || exit 1

    # Ensure .github/workflows directory exists
    mkdir -p .github/workflows

    # Copy the dispatch.yml file into the .github/workflows directory
    cp "$current_dir/$file" .github/workflows/dispatch.yml

    # Check if there are untracked or modified files, then commit and push
    if [[ -n $(git status --porcelain) ]]; then
      # Stage all changes
      git add .
      if git commit -m "Add or update dispatch.yml workflow"; then
        git push origin main || echo "Warning: Failed to push changes to $repo"
      else
        echo "Warning: No changes to commit for $repo"
      fi
    else
      echo "No changes detected for $repo"
    fi
  done

  # Return to the original working directory after function is complete
  cd "$current_dir" || exit 1
}


# Function to log in to Azure if not already logged in
ensure_azure_login() {
  if ! az account show &>/dev/null; then
    az login --use-device-code
  fi
}

# Function to select Azure subscription
select_subscription() {
  local current_sub_name current_sub_id confirm subscription_name

  current_sub_name=$(az account show --query "name" --output tsv 2>/dev/null)
  current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

  if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
    echo "Failed to retrieve current subscription. Ensure you are logged in to Azure."
    exit 1
  fi

  read -rp "Use the current default subscription: $current_sub_name (ID: $current_sub_id) (Y/n)? " confirm
  confirm=${confirm:-Y}  # Default to 'Y' if the user presses enter

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
    if [ ! -f "$key_path" ]; then
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

  if [[ -z "$clientId" || "$clientId" == "null" ]]; then
    echo "Error: Failed to retrieve or create the service principal. Exiting."
    exit 1
  fi

  # Check if role assignment already exists
  role_exists=$(az role assignment list --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" --query '[].id' -o tsv)

  if [[ -z "$role_exists" ]]; then
    # Create role assignment if it doesn't exist
    az role assignment create --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" || {
      echo "Failed to assign the role. Exiting."
      exit 1
    }
  fi
}

update_HTPASSWD() {
    # Check if the secret HTPASSWD exists
    if gh secret list | grep -q '^HTPASSWD\s'; then
        echo "The GitHub secret 'HTPASSWD' already exists."
        read -rp "Do you wish to change it? (N/y): " response
        response=${response:-N}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            read -srp "Enter new value for HTPASSWD: " new_htpasswd_value
            echo
            gh secret set HTPASSWD -b"$new_htpasswd_value" && sleep 10
        fi
    else
        read -srp "Enter value for HTPASSWD: " new_htpasswd_value
        echo
        gh secret set HTPASSWD -b "$new_htpasswd_value" && sleep 10
    fi
}

# Function to create GitHub secrets
create_github_secrets() {
  local secret_key
  secret_key=$(cat $HOME/.ssh/id_ed25519)

  for secret in \
    "AZURE_STORAGE_ACCOUNT_NAME:${PROJECT_NAME}account" \
    "TFSTATE_CONTAINER_NAME:${PROJECT_NAME}tfstate" \
    "AZURE_RESOURCE_GROUP_NAME:${PROJECT_NAME}-tfstate-RG" \
    "ARM_SUBSCRIPTION_ID:${subscriptionId}" \
    "ARM_TENANT_ID:${tenantId}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}" \
    "ACR_REGISTRY:${PROJECT_NAME}.azurecr.io" \
    "PROJECTNAME:${PROJECT_NAME}" \
    "LOCATION:${LOCATION}" \
    "PAT:$PAT" \
    "DEPLOYED:$DEPLOYED"; do
    key="${secret%%:*}"
    value="${secret#*:}"
    gh secret set "$key" -b "$value" || {
      echo "Error: Failed to set GitHub secret $key/$value. Exiting."
      exit 1
    }
    sleep 10
  done

  for repo in "${CONTENTREPOS[@]}"; do
    gh secret set PAT -b "$PAT" --repo ${GITHUB_ORG}/$repo || {
      echo "Error: Failed to set PAT secret for repository $repo. Exiting."
      exit 1
    }
    sleep 10
  done
  for repo in "${CONTENTREPOS[@]}"; do
    gh secret set CONTROL_REPO -b "${GITHUB_ORG}/${CONTROL_REPO}" --repo ${GITHUB_ORG}/$repo || {
      echo "Error: Failed to set CONTROL_REPO secret for repository $repo. Exiting."
      exit 1
    }
    sleep 10
  done
  for repo in "${CONTENTREPOS[@]}"; do
    secret_key=$(cat $HOME/.ssh/id_ed25519-$repo)
    normalized_repo=$(echo "$repo" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    gh secret set ${normalized_repo}_SSH_PRIVATE_KEY -b "$secret_key" || {
      echo "Error: Failed to set SSH private key secret for repository $repo. Exiting."
      exit 1
    }
    sleep 10
  done

}

# Function to handle deploy keys for repositories
handle_deploy_keys() {
  for repo in "${CONTENTREPOS[@]}"; do
    # Get the deploy key ID if it exists
    deploy_key_id=$(gh repo deploy-key list --repo ${GITHUB_ORG}/$repo --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')

    # Check if the deploy key exists and delete it if necessary
    if [[ -n "$deploy_key_id" ]]; then
      gh repo deploy-key delete --repo ${GITHUB_ORG}/$repo "$deploy_key_id" && sleep 10
    fi
    gh repo deploy-key add $HOME/.ssh/id_ed25519-${repo}.pub --title 'DEPLOY-KEY' --repo ${GITHUB_ORG}/$repo && sleep 10
  done
}

generate_github_action() {
  local tpl_file="docs-builder.tpl"
  local output_file=".github/workflows/docs-builder.yml"
  mkdir -p "$(dirname "$output_file")"

  # Start building the clone repo commands string
  local clone_commands=""
  clone_commands+="      - name: Clone Content\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"

  # Loop through each repository and append commands
  for repo in "${CONTENTREPOS[@]}"; do
    local secret_key_name="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
    clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
    clone_commands+="          echo '\${{ secrets.${secret_key_name} }}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
    clone_commands+="          mkdir -p src/${repo}/docs\n"
    clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${repo}.git src/${repo}/docs\n"
  done

  # Properly format and replace the placeholder with the generated clone commands
  echo -e "$clone_commands" | sed -e "/%%INSERTCLONEREPO%%/r /dev/stdin" -e "/%%INSERTCLONEREPO%%/d" "$tpl_file" | awk 'BEGIN { blank=0 } { if (/^$/) { blank++; if (blank <= 1) print; } else { blank=0; print; } }' > "$output_file"
  git add $output_file && git commit -m "updating docs-builder" && git switch -C docs-builder main && git push && gh pr create --title "Initializing repo" --body "Update docs builder" && gh pr merge -m --delete-branch
}

check_git_status() {
    # Check if the current directory is a Git repository
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: This script must be run from within a Git repository." >&2
        return 1
    fi

    # Fetch the latest changes from the remote repository
    git fetch &>/dev/null

    # Check if the local branch is up to date with the remote branch
    LOCAL_HASH=$(git rev-parse @)
    REMOTE_HASH=$(git rev-parse @{u})
    BASE_HASH=$(git merge-base @ @{u})

    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
        echo "Local repository is up to date with the remote."
    elif [ "$LOCAL_HASH" = "$BASE_HASH" ]; then
        echo "Error: Local repository is behind the remote. Please pull the latest changes." >&2
        return 1
    elif [ "$REMOTE_HASH" = "$BASE_HASH" ]; then
        echo "Local repository has unpushed commits."
    else
        echo "Local and remote repositories have diverged." >&2
        return 1
    fi
}

# Main execution flow
check_git_status
ensure_azure_login
ensure_github_login
prompt_for_PAT
select_subscription
create_azure_resources
create_service_principal "$SUBSCRIPTION_ID"
generate_ssh_keys
check_and_create_repos
update_HTPASSWD
create_github_secrets
clone_and_init_repo
handle_deploy_keys
generate_github_action
gh workflow run docs-builder
