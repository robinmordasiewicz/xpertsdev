name: "docs-builder"

on:
  repository_dispatch:
    types: [docs]
  workflow_dispatch:
  push:
    paths:
      - "Dockerfile"
      - "docs.conf"
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
  init:
    name: Job Init
    runs-on: ubuntu-latest
    outputs:
      action: ${{ steps.terraform.outputs.action }}
    steps:
      - id: terraform
        name: ${{ github.ref_name }}
        shell: bash
        run: |
          if [[ -n "${{ secrets.DEPLOYED }}" ]]
          then
            if [[ "${{ secrets.DEPLOYED }}" == "true" ]]
            then
              echo 'action=build' >> "${GITHUB_OUTPUT}"
            fi
          else
            echo 'action=skip' >> "${GITHUB_OUTPUT}"
          fi

  build:
    name: Build Container
    if: needs.init.outputs.action == 'build'
    runs-on: ubuntu-latest
    needs: [init]
    steps:
      - name: Github repository checkout
        uses: actions/checkout@eef61447b9ff4aafe5dcd4e0bbf5d482be7e7871
 
      - name: Check for VERSION file and set version
        id: set_version
        run: |
          # Check if VERSION file exists
          if [ -f VERSION ]; then
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
          echo "image_version=$NEW_VERSION" >> $GITHUB_ENV
          echo "image_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"

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

      - name: Build MkDocs site
        run: |
          docker run --rm -v ${{ github.workspace }}:/docs ghcr.io/amerintlxperts/mkdocs:latest build -c -d site/

      - name: Create htaccess password
        run: |
          pwd
          htpasswd -b -c .htpasswd ${{ secrets.PROJECTNAME }} ${{ secrets.HTPASSWD }}
          ls -la
  
      - name: Microsoft Azure Authentication
        uses: azure/login@a65d910e8af852a8061c627c456678983e180302
        with:
          allow-no-subscriptions: true
          creds: ${{ secrets.AZURE_CREDENTIALS }}
  
      - name: ACR login
        uses: azure/docker-login@15c4aadf093404726ab2ff205b2cdd33fa6d054c
        with:
          login-server: "${{ secrets.ACR_LOGIN_SERVER }}.azurecr.io"
          username: ${{ secrets.ARM_CLIENT_ID }}
          password: ${{ secrets.ARM_CLIENT_SECRET }}
  
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349
  
      - name: Build and Push Docker Image
        uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75
        with:
          context: .
          push: true
          tags: ${{ secrets.ACR_LOGIN_SERVER }}.azurecr.io/docs:${{ env.image_version }},${{ secrets.ACR_LOGIN_SERVER }}.azurecr.io/docs:latest

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
          rm .htpasswd
   
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
        uses: peter-evans/enable-pull-request-automerge@a660677d5469627102a1c1e11409dd063606628d
        env:
          GH_TOKEN: ${{ secrets.PAT }}
        with:
          token: ${{ secrets.PAT }}
          pull-request-number: ${{ steps.create_pr.outputs.pull-request-number }}
          merge-method: squash
        
  
