name: "docs-builder"

on:
  repository_dispatch:
    types: [docs]
  workflow_dispatch:
  push:
    paths:
      - "terraform/**.tf"
      - "Dockerfile"
      - "docs.conf"
      - "docs/**"
      - "mkdocs.yml"
    branches:
      - "main"

permissions:
  id-token: write
  contents: write
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  terraform:
    name: Job Init
    runs-on: ubuntu-latest
    outputs:
      action: ${{ steps.terraform.outputs.action }}
    steps:
      - id: terraform
        name: ${{ github.ref_name }} deployed is ${{ vars.DEPLOYED }}
        shell: bash
        run: |
          env
          if [[ -n "${{ vars.DEPLOYED }}" ]]
          then
            if [[ "${{ vars.DEPLOYED }}" == "true" ]]
            then
              echo 'action=apply' >> "${GITHUB_OUTPUT}"
            else
              echo 'action=destroy' >> "${GITHUB_OUTPUT}"
            fi
          else
            echo 'action=skip' >> "${GITHUB_OUTPUT}"
          fi

  plan:
    needs: [terraform]
    if: needs.terraform.outputs.action == 'apply'
    name: Terraform Plan
    runs-on: ubuntu-latest
    env:
      ARM_SKIP_PROVIDER_REGISTRATION: true
    outputs:
      tfplanExitCode: ${{ steps.tf-plan.outputs.exitcode }}
      image_version: ${{ steps.set_version.outputs.image_version }}

    steps:
      - name: Github repository checkout
        uses: actions/checkout@eef61447b9ff4aafe5dcd4e0bbf5d482be7e7871

      - name: Microsoft Azure Authentication
        uses: azure/login@a65d910e8af852a8061c627c456678983e180302
        with:
          allow-no-subscriptions: true
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Hashicorp Terraform
        uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd
        with:
          terraform_wrapper: false

      - name: terraform init
        id: init
        env:
          ARM_SUBSCRIPTION_ID: ${{ secrets.ARM_SUBSCRIPTION_ID }}
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.ARM_TENANT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_IN_AUTOMATION: true
          TF_CLI_ARGS_init: -backend-config="storage_account_name=${{ secrets.AZURE_STORAGE_ACCOUNT_NAME }}" -backend-config="container_name=${{ secrets.TFSTATE_CONTAINER_NAME }}" -backend-config="resource_group_name=${{ secrets.AZURE_RESOURCE_GROUP_NAME }}" -backend-config="key=${{ github.ref_name }}" -input=false
        run: terraform -chdir=terraform init

      - name: Check for VERSION file and set version
        id: set_version
        run: |
          # Check if VERSION file exists
          if [ -f VERSION ]; then
            echo "VERSION file exists."
            VERSION=$(cat VERSION)
            if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              echo "VERSION file does not contain a valid semantic version. Exiting."
              exit 1
            fi
            IFS='.' read -r -a version_parts <<< "$VERSION"
            ((version_parts[2]++))
            NEW_VERSION="${version_parts[0]}.${version_parts[1]}.${version_parts[2]}"
          else
            echo "VERSION file does not exist. Setting version to 0.0.1."
            NEW_VERSION="0.0.1"
          fi
          echo "New version: $NEW_VERSION"
          echo "image_version=$NEW_VERSION" >> $GITHUB_ENV
          echo "image_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"

      - name: terraform plan
        id: tf-plan
        env:
          ARM_SUBSCRIPTION_ID: ${{ secrets.ARM_SUBSCRIPTION_ID }}
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.ARM_TENANT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_VAR_project: ${{ secrets.PROJECTNAME }}
          TF_VAR_location: ${{ secrets.LOCATION }}
          TF_VAR_image_version: ${{ env.image_version }}
          TF_VAR_github_token: ${{ secrets.PAT }}
          TF_IN_AUTOMATION: true
          TF_VAR_acr-username: ${{ secrets.ARM_CLIENT_ID }}
          TF_VAR_acr-password: ${{ secrets.ARM_CLIENT_SECRET }}
        run: |
          export exitcode=0
          terraform -chdir=terraform plan -detailed-exitcode -no-color -out tfplan || export exitcode=$?
          echo "exitcode=$exitcode" >> "$GITHUB_OUTPUT"
          if [ $exitcode -eq 1 ]; then
            echo Terraform Plan Failed!
            exit 1
          else
            exit 0
          fi

      - name: Publish Terraform Plan
        uses: actions/upload-artifact@b4b15b8c7c6ac21ea08fcf65892d2ee8f75cf882
        with:
          name: tfplan
          path: terraform/tfplan

      - name: Create String Output
        id: tf-plan-string
        run: |
          TERRAFORM_PLAN=$(terraform -chdir=terraform show -no-color tfplan)
          delimiter="$(openssl rand -hex 8)"
          {
            echo "summary<<${delimiter}"
            echo "## Terraform Plan Output"
            echo "<details><summary>Click to expand</summary>"
            echo ""
            echo '```terraform'
            echo "$TERRAFORM_PLAN"
            echo '```'
            echo "</details>"
            echo "${delimiter}"
          } >> "$GITHUB_OUTPUT"

      - name: Publish Terraform Plan to Task Summary
        env:
          SUMMARY: ${{ steps.tf-plan-string.outputs.summary }}
        run: |
          echo "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"

  apply:
    name: Terraform Apply
    if: needs.terraform.outputs.action == 'apply'
    runs-on: ubuntu-latest
    needs: [terraform, plan]
    env:
      image_version: ${{ needs.plan.outputs.image_version }}
    steps:
      - name: Github repository checkout
        uses: actions/checkout@eef61447b9ff4aafe5dcd4e0bbf5d482be7e7871

      - name: Install mkdocs
        run: |
          pip install --upgrade pip
          pip install material mkdocs-awesome-pages-plugin mkdocs-git-authors-plugin mkdocs-git-committers-plugin-2 mkdocs-git-revision-date-localized-plugin mkdocs-glightbox mkdocs-material[imaging] mkdocs-minify-plugin mkdocs-monorepo-plugin mkdocs-pdf-export-plugin mkdocs-same-dir mkdocstrings[crystal,python] mkdocs-with-pdf pymdown-extensions mkdocs-enumerate-headings-plugin mkdocs-exclude

      - name: setup ssh config
        shell: bash
        run: |
          mkdir -p ~/.ssh
          cat << EOF > ~/.ssh/config
          Host xxx
            HostName github.com
            User git
            IdentityFile ~/.ssh/id_ed25519
            StrictHostKeyChecking no
          EOF

      %%INSERTCLONEREPO%%

      - name: Build Docs
        shell: bash
        run: |
          REPOS=$(jq -r '.REPOS[]' config.json)
          mkdocs build -c -d site/
          for repo in ${REPOS}; do
            cp -a docs/theme src/${repo}/docs/
            echo "---" > /home/runner/work/_temp/${repo}/mkdocs.yml
            echo "INHERIT: docs/theme/mkdocs.yml" >> /home/runner/work/_temp/${repo}/mkdocs.yml
            cd /home/runner/work/_temp/${repo} && mkdocs build -d /home/runner/work/_temp/build/${repo}
            mv /home/runner/work/_temp/build/${repo} /home/runner/work/_temp/site/
          done

      - name: Create htaccess password
        run: |
          htpasswd -b -c .htpasswd ${{ secrets.PROJECTNAME }} ${{ secrets.HTPASSWD }}
  
      - name: Microsoft Azure Authentication
        uses: azure/login@a65d910e8af852a8061c627c456678983e180302
        with:
          allow-no-subscriptions: true
          creds: ${{ secrets.AZURE_CREDENTIALS }}
  
      - name: ACR login
        uses: azure/docker-login@15c4aadf093404726ab2ff205b2cdd33fa6d054c
        with:
          login-server: "${{ secrets.PROJECTNAME }}.azurecr.io"
          username: ${{ secrets.ARM_CLIENT_ID }}
          password: ${{ secrets.ARM_CLIENT_SECRET }}
  
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349
  
      - name: Build Container  
        run: |
          docker build -t ${{ secrets.PROJECTNAME }}.azurecr.io/docs:${{ env.image_version }} .
      
      - name: Hashicorp Terraform
        uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd
        with:
          terraform_wrapper: false
  
      - name: terraform init
        id: init
        env:
          ARM_SUBSCRIPTION_ID: ${{ secrets.ARM_SUBSCRIPTION_ID }}
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.ARM_TENANT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_IN_AUTOMATION: true
          TF_CLI_ARGS_init: -backend-config="storage_account_name=${{ secrets.AZURE_STORAGE_ACCOUNT_NAME }}" -backend-config="container_name=${{ secrets.TFSTATE_CONTAINER_NAME }}" -backend-config="resource_group_name=${{ secrets.AZURE_RESOURCE_GROUP_NAME }}" -backend-config="key=${{ github.ref_name }}" -input=false
        run: terraform -chdir=terraform init
  
      - name: Download Terraform Plan
        uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16
        with:
          name: tfplan
          path: terraform          

      - name: Terraform Apply
        id: apply
        env:
          ARM_SUBSCRIPTION_ID: ${{ secrets.ARM_SUBSCRIPTION_ID }}
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_VAR_project: ${{ secrets.PROJECTNAME }}
          TF_VAR_location: ${{ secrets.LOCATION }}
          TF_VAR_image_version: ${{ env.image_version }}
          TF_VAR_acr-username: ${{ secrets.ARM_CLIENT_ID }}
          TF_VAR_acr-password: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_VAR_github_token: ${{ secrets.PAT }}
          ARM_TENANT_ID: ${{ secrets.ARM_TENANT_ID }}
          TF_IN_AUTOMATION: true
        run: terraform -chdir=terraform apply -auto-approve tfplan

      - name: Configure Git
        run: |
          git config --global user.name "github-actions[bot]"
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
     
      - name: Delete Remote Branch if it Exists
        run: |
          git ls-remote --exit-code --heads origin update-version-${{ env.image_version }} && \
          git push origin --delete update-version-${{ env.image_version }} || echo "Branch does not exist"
     
      - name: Update VERSION file
        run: |
          echo "${{ env.image_version }}" > VERSION
          rm -rf docs/theme/
          rm -rf src/
          rm terraform/tfplan
   
      - name: Create Pull Request
        id: create_pr
        uses: peter-evans/create-pull-request@5e914681df9dc83aa4e4905692ca88beb2f9e91f
        with:
          commit-message: "Update VERSION to ${{ env.image_version }}"
          branch: update-version-${{ env.image_version }}
          base: main
          title: "Update VERSION to ${{ env.image_version }}"
          body: "Automatically generated pull request to update the VERSION file to ${{ env.image_version }}."

      - name: Enable Pull Request Automerge
        if: steps.create_pr.outputs.pull-request-operation == 'created'
        uses: peter-evans/enable-pull-request-automerge@v3
        env:
          GH_TOKEN: ${{ secrets.PAT }}
        with:
          token: ${{ secrets.PAT }}
          pull-request-number: ${{ steps.create_pr.outputs.pull-request-number }}
          merge-method: squash
        
  destroy:
    name: Terraform Destroy
    needs: [terraform]
    if: needs.terraform.outputs.action == 'destroy'
    runs-on: ubuntu-latest
    steps:
      - name: Github repository checkout
        uses: actions/checkout@eef61447b9ff4aafe5dcd4e0bbf5d482be7e7871

      - name: Microsoft Azure Authentication
        uses: azure/login@a65d910e8af852a8061c627c456678983e180302
        with:
          allow-no-subscriptions: true
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Hashicorp Terraform
        uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd
        with:
          terraform_wrapper: false

      - name: terraform init
        id: init
        env:
          ARM_SUBSCRIPTION_ID: ${{ secrets.ARM_SUBSCRIPTION_ID }}
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.ARM_TENANT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_IN_AUTOMATION: true
          TF_CLI_ARGS_init: -backend-config="storage_account_name=${{ secrets.AZURE_STORAGE_ACCOUNT_NAME }}" -backend-config="container_name=${{ secrets.TFSTATE_CONTAINER_NAME }}" -backend-config="resource_group_name=${{ secrets.AZURE_RESOURCE_GROUP_NAME }}" -backend-config="key=${{ github.ref_name }}" -input=false
        run: terraform -chdir=terraform init

      - name: terraform destroy
        id: destroy
        env:
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ secrets.ARM_SUBSCRIPTION_ID }}
          ARM_TENANT_ID: ${{ secrets.ARM_TENANT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_VAR_project: ${{ secrets.PROJECTNAME }}
          TF_VAR_location: ${{ secrets.LOCATION }}
          TF_VAR_image_version: ${{ env.image_version }}
          TF_VAR_acr-username: ${{ secrets.ARM_CLIENT_ID }}
          TF_VAR_acr-password: ${{ secrets.ARM_CLIENT_SECRET }}
          TF_VAR_github_token: ${{ secrets.PAT }}
          TF_IN_AUTOMATION: true
        run: terraform -chdir=terraform destroy -auto-approve