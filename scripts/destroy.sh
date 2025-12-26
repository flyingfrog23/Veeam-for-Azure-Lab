#!/usr/bin/env bash
set -euo pipefail

# scripts/destroy.sh
# Destroys the lab:
# - deletes the Marketplace managed application (if deployed)
# - deletes the managed resource group created by the managed application (best-effort)
# - deletes the main lab resource group

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"

# Marketplace parameter file (optional)
PARAM_FILE="${PARAM_FILE:-marketplace/vbazure.parameters.json}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

echo "==> Setting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"

# Best-effort: remove managed app + its managed RG if the parameters file exists
if [[ -f "${PARAM_FILE}" ]]; then
  APP_NAME="$(jq -r '.parameters.managedApplicationName.value // empty' "${PARAM_FILE}")"
  MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${PARAM_FILE}")"

  if [[ -n "${APP_NAME}" ]]; then
    echo "==> Deleting managed application (best-effort): ${APP_NAME}"
    az resource delete \
      --resource-group "${RG_NAME}" \
      --resource-type "Microsoft.Solutions/applications" \
      --name "${APP_NAME}" \
      1>/dev/null || true
  fi

  if [[ -n "${MRG_NAME}" ]]; then
    echo "==> Deleting managed resource group (best-effort): ${MRG_NAME}"
    az group delete -n "${MRG_NAME}" --yes --no-wait 1>/dev/null || true
  fi
else
  echo "==> ${PARAM_FILE} not found; skipping managed app cleanup."
fi

echo "==> Deleting main resource group ${RG_NAME}"
az group delete -n "${RG_NAME}" --yes --no-wait

echo "==> Delete initiated: ${RG_NAME}"
