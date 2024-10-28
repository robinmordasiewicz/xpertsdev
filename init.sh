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
DOCS_USERNAME=$(jq -r '.PROJECT_NAME' "$INITJSON")
LOCATION=$(jq -r '.LOCATION' "$INITJSON")
THEME_REPO_NAME=$(jq -r '.THEME_REPO_NAME' "$INITJSON")
LANDING_PAGE_REPO_NAME=$(jq -r '.LANDING_PAGE_REPO_NAME' "$INITJSON")
DOCS_BUILDER_REPO_NAME=$(jq -r '.DOCS_BUILDER_REPO_NAME' "$INITJSON")
INFRASTRUCTURE_REPO_NAME=$(jq -r '.INFRASTRUCTURE_REPO_NAME' "$INITJSON")
MANIFESTS_REPO_NAME=$(jq -r '.MANIFESTS_REPO_NAME' "$INITJSON")
MKDOCS_REPO_NAME=$(jq -r '.MKDOCS_REPO_NAME' "$INITJSON")

readarray -t CONTENTREPOS < <(jq -r '.REPOS[]' "$INITJSON")
readarray -t CONTENTREPOSONLY < <(jq -r '.REPOS[]' "$INITJSON")
CONTENTREPOS+=("$THEME_REPO_NAME")
CONTENTREPOS+=("$LANDING_PAGE_REPO_NAME")
readarray -t ALLREPOS < <(jq -r '.REPOS[]' "$INITJSON")
ALLREPOS+=("$THEME_REPO_NAME")
ALLREPOS+=("$LANDING_PAGE_REPO_NAME")
ALLREPOS+=("$DOCS_BUILDER_REPO_NAME")
ALLREPOS+=("$INFRASTRUCTURE_REPO_NAME")
ALLREPOS+=("$MANIFESTS_REPO_NAME")

current_dir=$(pwd)
max_retries=3
retry_interval=5

# Check if variables were properly initialized
if [[ -z "$DEPLOYED" || -z "$PROJECT_NAME" || -z "$LOCATION" || ${#CONTENTREPOS[@]} -eq 0 ]]; then
  echo "Error: Failed to initialize variables from $INITJSON. Exiting."
  exit 1
fi

# Extract GitHub organization and control repo
GITHUB_ORG=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')
PROJECT_NAME="${GITHUB_ORG}-${PROJECT_NAME}"
AZURE_STORAGE_ACCOUNT_NAME=$(echo "{$PROJECT_NAME}account" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z' | cut -c 1-24)
if [[ "$MKDOCS_REPO_NAME" != */* ]]; then
  MKDOCS_REPO_NAME="ghcr.io/${GITHUB_ORG}/${MKDOCS_REPO_NAME}"
fi
if [[ "$MKDOCS_REPO_NAME" != *:* ]]; then
  MKDOCS_REPO_NAME="${MKDOCS_REPO_NAME}:latest"
fi
#CONTROL_REPO_NAME=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)\.git#\1#p')

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

check_and_create_repos() {
  for repo in "${CONTENTREPOS[@]}"; do
    if ! repo_exists "$repo"; then
      read -rp "Create repository '$repo' in organization '$GITHUB_ORG'? (Y/n)" create_repo
      create_repo=${create_repo:-Y}
      if [[ "$create_repo" =~ ^[Yy]$ ]]; then
        gh repo create "${GITHUB_ORG}/${repo}" --private
      else
        echo "Repository creation aborted. Exiting."
        exit 1
      fi
    fi
  done
}

copy_dispatch-workflow_to_content_repos() {
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

ensure_azure_login() {
  # Check if the account is currently active
  if ! az account show &>/dev/null; then
    echo "No active Azure session found. Logging in..."
    az login --use-device-code
  else
    # Check if the token is still valid
    if ! az account get-access-token &>/dev/null; then
      echo "Azure login has expired. Logging in again..."
      az login --use-device-code
    else
      echo "Azure login is active."
    fi
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
  for repo in "${ALLREPOS[@]}"; do
    local key_path="$HOME/.ssh/id_ed25519-$repo"
    if [ ! -f "$key_path" ]; then
      ssh-keygen -t ed25519 -N "" -f "$key_path" -q
    fi
  done
}

create_azure_resources() {
  # Check if resource group exists
  if ! az group show -n "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az group create -n "${PROJECT_NAME}-tfstate" -l "${LOCATION}"
  fi

  # Check if storage account exists
  if ! az storage account show -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az storage account create -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" -l "${LOCATION}" --sku Standard_LRS
  fi

  # Check if storage container exists
  if ! az storage container show -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" &>/dev/null; then
    az storage container create -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" --auth-mode login
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

update_DOCS_HTPASSWD() {
    # Check if the secret HTPASSWD exists
    if gh secret list --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME | grep -q '^HTPASSWD\s'; then
        read -rp "Change the Docs HTPASSWD? (N/y): " response
        response=${response:-N}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            read -srp "Enter new value for Docs HTPASSWD: " new_htpasswd_value
            echo
            if gh secret set HTPASSWD -b "$new_htpasswd_value" --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME; then
              echo "Updated Docs Password"
            else
              if [[ $attempt -lt $max_retries ]]; then
                echo "Warning: Failed to set GitHub secret HTPASSWD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                sleep $retry_interval
              else
                echo "Error: Failed to set GitHub secret HTPASSWD after $max_retries attempts. Exiting."
                exit 1
              fi
            fi
        fi
    else
        read -srp "Enter value for Docs HTPASSWD: " new_htpasswd_value
        echo
        if gh secret set HTPASSWD -b "$new_htpasswd_value" --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME; then
          echo "Updated Docs Password"
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub secret HTPASSWD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub secret HTPASSWD after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
    fi
}

update_HUB_NVA_CREDENTIALS() {
    if gh secret list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME | grep -q '^HUB_NVA_PASSWORD\s'; then
        read -rp "Change the Hub NVA Password? (N/y): " response
        response=${response:-N}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            read -srp "Enter new password for the HUB NVA: " new_htpasswd_value
            echo
            if gh secret set HUB_NVA_PASSWORD -b "$new_htpasswd_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
              break
            else
              if [[ $attempt -lt $max_retries ]]; then
                echo "Warning: Failed to set GitHub secret HUB_NVA_PASSWORD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                sleep $retry_interval
              else
                echo "Error: Failed to set GitHub secret HUB_NVA_PASSWORD after $max_retries attempts. Exiting."
                exit 1
              fi
            fi
            if gh secret set HUB_NVA_USERNAME -b "${GITHUB_ORG}" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
              break
            else
              if [[ $attempt -lt $max_retries ]]; then
                echo "Warning: Failed to set GitHub secret HUB_NVA_USERNAME. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                sleep $retry_interval
              else
                echo "Error: Failed to set GitHub secret HUB_NVA_USERNAME after $max_retries attempts. Exiting."
                exit 1
              fi
            fi
        fi
    else
        read -srp "Enter value for Hub NVA Password: " new_htpasswd_value
        echo
        if gh secret set HUB_NVA_PASSWORD -b "$new_htpasswd_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          echo "Password set"
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub secret HUB_NVA_PASSWORD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub secret HUB_NVA_PASSWORD after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
        if gh secret set HUB_NVA_USERNAME -b "${GITHUB_ORG}"  --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          becho "Username set"
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub secret HUB_NVA_USERNAME. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub secret HUB_NVA_USERNAME after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
    fi
}

# Function to create GitHub secrets
create_infrastructure_secrets() {

  for secret in \
    "AZURE_STORAGE_ACCOUNT_NAME:${AZURE_STORAGE_ACCOUNT_NAME}" \
    "TFSTATE_CONTAINER_NAME:${PROJECT_NAME}tfstate" \
    "AZURE_TFSTATE_RESOURCE_GROUP_NAME:${PROJECT_NAME}-tfstate" \
    "ARM_SUBSCRIPTION_ID:${subscriptionId}" \
    "ARM_TENANT_ID:${tenantId}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}" \
    "PROJECT_NAME:${PROJECT_NAME}" \
    "LOCATION:${LOCATION}" \
    "PAT:$PAT" \
    "DOCS_BUILDER_REPO_NAME:$DOCS_BUILDER_REPO_NAME" \
    "MANIFESTS_SSH_PRIVATE_KEY:$(cat $HOME/.ssh/id_ed25519-manifests)" \
    "MANIFESTS_REPO_NAME:${GITHUB_ORG}/${MANIFESTS_REPO_NAME}" \
    "DEPLOYED:$DEPLOYED"; do
    key="${secret%%:*}"
    value="${secret#*:}"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "$key" -b "$value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

create_docs-builder_secrets() {
  local secret_key

  for secret in \
    "DOCS_USERNAME:${DOCS_USERNAME}" \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" \
    "DEPLOYED:$DEPLOYED" \
    "MKDOCS_REPO_NAME:$MKDOCS_REPO_NAME" \
    "MANIFESTS_REPO_NAME:$MANIFESTS_REPO_NAME" \
    "PAT:$PAT"; do
    key="${secret%%:*}"
    value="${secret#*:}"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "$key" -b "$value" --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done

  for repo in "${CONTENTREPOS[@]}"; do
    secret_key=$(cat $HOME/.ssh/id_ed25519-$repo)
    normalized_repo=$(echo "$repo" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set ${normalized_repo}_SSH_PRIVATE_KEY -b "$secret_key" --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

create_manifests_secrets() {
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "PAT" -b "${PAT}" --repo ${GITHUB_ORG}/${MANIFESTS_REPO_NAME}; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret PAT. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret PAT after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
}

create_content-repo_secrets() {
  for repo in "${CONTENTREPOS[@]}"; do
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "DOCS_BUILDER_REPO_NAME" -b "${DOCS_BUILDER_REPO_NAME}" --repo ${GITHUB_ORG}/$repo; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret DOCS_BUILDER_REPO_NAME. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret DOCS_BUILDER_REPO_NAME after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

handle_deploy_keys() {
  for repo in "${ALLREPOS[@]}"; do
    deploy_key_id=$(gh repo deploy-key list --repo ${GITHUB_ORG}/$repo --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
    if [[ -n "$deploy_key_id" ]]; then
      gh repo deploy-key delete --repo ${GITHUB_ORG}/$repo "$deploy_key_id"
    fi
    gh repo deploy-key add $HOME/.ssh/id_ed25519-${repo}.pub --title 'DEPLOY-KEY' --repo ${GITHUB_ORG}/$repo
  done
}

copy_docs-builder-workflow_to_docs-builder_repo() {
  local tpl_file="${current_dir}/docs-builder.tpl"
  local github_token="$PAT"
  local output_file=".github/workflows/docs-builder.yml"
  local theme_secret_key_name="$(echo "$THEME_REPO_NAME" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"

  # Use a trap to ensure that temporary directories are cleaned up safely
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  # Check if dispatch.yml tpl_file exists before proceeding
  if [[ ! -f "$tpl_file" ]]; then
    echo "Error: File $tpl_file not found. Please ensure it is present in the current directory."
    exit 1
  fi
  cd "$TEMP_DIR" || exit 1
  if ! git clone "https://$github_token@github.com/${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
    echo "Error: Failed to clone repository $DOCS_BUILDER_REPO_NAME"
    continue
  fi

  cd "$DOCS_BUILDER_REPO_NAME" || exit 1
  mkdir -p "$(dirname "$output_file")"

  # Start building the clone repo commands string
  local clone_commands=""
  local landing_page_secret_key_name="$(echo "${LANDING_PAGE_REPO_NAME}" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
  clone_commands+="      - name: Clone Landing Page\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
  clone_commands+="          echo '\${{ secrets.${landing_page_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
  clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${LANDING_PAGE_REPO_NAME}.git \$TEMP_DIR/docs\n\n"

  clone_commands+="      - name: Link mkdocs.yml\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          echo 'INHERIT: docs/theme/mkdocs.yml' > \$TEMP_DIR/mkdocs.yml\n\n"

  local theme_secret_key_name="$(echo "${THEME_REPO_NAME}" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
  clone_commands+="      - name: Clone Theme\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
  clone_commands+="          echo '\${{ secrets.${theme_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
  clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${THEME_REPO_NAME}.git \$TEMP_DIR/docs/theme\n\n"
  
  clone_commands+="      - name: Clone Content Repos\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"

  for repo in "${CONTENTREPOSONLY[@]}"; do
    local secret_key_name="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
    clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
    clone_commands+="          echo '\${{ secrets.${secret_key_name} }}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
    clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${repo}.git \$TEMP_DIR/docs/${repo}\n"
  done

  echo -e "$clone_commands" | sed -e "/%%INSERTCLONEREPO%%/r /dev/stdin" -e "/%%INSERTCLONEREPO%%/d" "$tpl_file" | awk 'BEGIN { blank=0 } { if (/^$/) { blank++; if (blank <= 1) print; } else { blank=0; print; } }' > "$output_file"

  if [[ -n $(git status --porcelain) ]]; then
    git add $output_file 
    if git commit -m "Add or update docs-builder.yml workflow"; then
      git switch -C docs-builder main && git push && gh pr create --title "Initializing repo" --body "Update docs builder" && gh pr merge -m --delete-branch || echo "Warning: Failed to push changes to $repo"
    else
      echo "Warning: No changes to commit for $repo"
    fi
  else
    echo "No changes detected for $repo"
  fi
  cd "$current_dir" || exit 1

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
handle_deploy_keys
update_DOCS_HTPASSWD
create_docs-builder_secrets
create_manifests_secrets
copy_docs-builder-workflow_to_docs-builder_repo
update_HUB_NVA_CREDENTIALS
create_infrastructure_secrets
create_content-repo_secrets
copy_dispatch-workflow_to_content_repos
