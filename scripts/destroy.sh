#!/usr/bin/env bash
set -euo pipefail

# scripts/destroy.sh
# Destroys the whole lab by deleting the resource group.

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

echo "==> Setting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"

echo "==> Deleting resource group ${RG_NAME}"
az group delete -n "${RG_NAME}" --yes --no-wait

echo "==> Delete initiated: ${RG_NAME}"
