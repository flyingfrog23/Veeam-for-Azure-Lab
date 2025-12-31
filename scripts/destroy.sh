#!/usr/bin/env bash
set -euo pipefail

# Destroys the lab by deleting the resource groups.
#
# Required:
#   SUBSCRIPTION_ID
#
# Optional:
#   RG_NAME (default: veeam-lab-rg)
#   VBMA_MRG_NAME (default: veeam-vbma-mrg)
#

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-veeam-vbma-mrg}"

az account set --subscription "${SUBSCRIPTION_ID}"

echo "==> Deleting resource group: ${RG_NAME}"
az group delete -n "${RG_NAME}" --yes --no-wait

# Best-effort cleanup of the Marketplace managed RG
if [[ -n "${VBMA_MRG_NAME}" ]]; then
  echo "==> Deleting managed resource group (best-effort): ${VBMA_MRG_NAME}"
  az group delete -n "${VBMA_MRG_NAME}" --yes --no-wait || true
fi

echo "==> Delete initiated."
