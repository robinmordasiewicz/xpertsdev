name: dispatch

concurrency:
  group: ${{ github.workflow }}

permissions:
  id-token: write
  contents: write

on: # yamllint disable-line rule:truthy
  workflow_dispatch:
  push:
    branches: [main]
    paths-ignore:
      - '.github/**'

jobs:
  terraform:
    name: "Trigger Build"
    runs-on: ubuntu-latest
    steps:
      - name: Repository Dispatch
        uses: peter-evans/repository-dispatch@ff45666b9427631e3450c54a1bcbee4d9ff4d7c0
        with:
          token: ${{ secrets.PAT }}
          repository: ${{ secrets.DOCS_BUILDER_REPO_NAME }}
          event-type: docs
          client-payload: '{"ref": "${{ github.ref }}", "sha": "${{ github.sha }}"}'