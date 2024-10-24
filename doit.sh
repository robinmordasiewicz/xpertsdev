#!/bin/bash
#

az acr repository list --name ddibwzzmtpldcnvemtqjegdzl --output table | while read repo; do
    az acr repository show-tags --name ddibwzzmtpldcnvemtqjegdzl --repository $repo --output table | awk -v repo=$repo '{print repo ":" $0}';
  done

