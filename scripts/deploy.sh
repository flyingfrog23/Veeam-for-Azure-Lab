#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# using marketplace/vbazure.parameters.json (or env var overrides).

# ---- Required env vars (or edit defaults below) ----
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"

ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"   # required unless you edit to prompt securely
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# Marketplace toggle
DEPLOY_VBMA="${DEPLOY_VBMA:-false}"  # true/false

# Optional marketplace overrides via env (if set, they win over parameter file)
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"
# Optional JSON object string for managed app parameters (e.g. '{"foo":"bar"}')
VBMA_APP_PARAMS_JSON="${VBMA_APP_PARAMS_JSON:-}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "ERROR: ADMIN_PASSWORD is required (set env var)."
  exit 1
fi

echo "==> Setting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"

echo "==> Creating resource group ${RG_NAME} in ${LOCATION}"
az group create -n "${RG_NAME}" -l "${LOCATION}" 1>/dev/null

echo "==> Deploying baseline lab (Bicep)"
az deployment group create \
  -g "${RG_NAME}" \
  -n "baseline-$(date +%Y%m%d%H%M%S)" \
  -f "${REPO_ROOT}/infra/main.bicep" \
  -p prefix="${PREFIX}" \
     location="${LOCATION}" \
     adminUsername="${ADMIN_USERNAME}" \
     adminPassword="${ADMIN_PASSWORD}" \
     allowedRdpSource="${ALLOWED_RDP_SOURCE}" \
  1>/dev/null

echo "==> Baseline deployed."

if [[ "${DEPLOY_VBMA}" != "true" ]]; then
  echo "==> Skipping marketplace deployment (set DEPLOY_VBMA=true to enable)."
  exit 0
fi

# ---- Marketplace deployment (Managed App) ----
PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"
if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "ERROR: Missing ${PARAM_FILE}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for marketplace deployment. Install jq or set DEPLOY_VBMA=false."
  exit 1
fi

# jq can fail with "Invalid numeric literal" if the file has a UTF-8 BOM.
# Create a sanitized temp copy and always read from that.
SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"

cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# Strip UTF-8 BOM if present (EF BB BF)
sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

echo "==> Reading marketplace parameters from ${PARAM_FILE}"

# Read from file (fallbacks), then override with env if provided
FILE_PUBLISHER="$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")"
FILE_OFFER="$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")"
FILE_PLAN="$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")"
FILE_PLAN_VERSION="$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")"
FILE_APP_NAME="$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")"
FILE_MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")"
FILE_APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"

PUBLISHER="${VBMA_PUBLISHER:-$FILE_PUBLISHER}"
OFFER="${VBMA_OFFER:-$FILE_OFFER}"
PLAN="${VBMA_PLAN:-$FILE_PLAN}"
PLAN_VERSION="${VBMA_PLAN_VERSION:-$FILE_PLAN_VERSION}"
APP_NAME="${VBMA_APP_NAME:-$FILE_APP_NAME}"
MRG_NAME="${VBMA_MRG_NAME:-$FILE_MRG_NAME}"

# App parameters: env override if set; otherwise from file; always validate and write to file
if [[ -n "${VBMA_APP_PARAMS_JSON}" ]]; then
  # validate/compact
  APP_PARAMS_JSON="$(printf '%s' "${VBMA_APP_PARAMS_JSON}" | jq -c '.')"
else
  APP_PARAMS_JSON="${FILE_APP_PARAMS_JSON}"
fi
# Ensure we always have a JSON object
if [[ -z "${APP_PARAMS_JSON}" || "${APP_PARAMS_JSON}" == "null" ]]; then
  APP_PARAMS_JSON="{}"
fi
printf '%s\n' "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"

if [[ -z "${PUBLISHER}" || -z "${OFFER}" || -z "${PLAN}" || -z "${PLAN_VERSION}" || -z "${APP_NAME}" || -z "${MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "       Need: publisher, offer, plan, planVersion, managedApplicationName, managedResourceGroupName"
  echo "       Provide via env (VBMA_*) or in ${PARAM_FILE}."
  exit 1
fi

echo "==> Ensuring managed resource group exists: ${MRG_NAME}"
az group create -n "${MRG_NAME}" -l "${LOCATION}" 1>/dev/null

# IMPORTANT: use the *actual* resource ID from Azure (avoids InvalidApplicationManagedResourceGroupId)
MRG_ID="$(az group show -n "${MRG_NAME}" --query id -o tsv)"

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN})"
# Best-effort: different tenants/environments expose different commands
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  true

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"
echo "    App RG: ${RG_NAME}"
echo "    Managed RG: ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"

# Always pass parameters as a file to avoid shell/JSON parsing issues
az managedapp create \
  -g "${RG_NAME}" \
  -n "${APP_NAME}" \
  -l "${LOCATION}" \
  --kind MarketPlace \
  -m "${MRG_ID}" \
  --plan-name "${PLAN}" \
  --plan-product "${OFFER}" \
  --plan-publisher "${PUBLISHER}" \
  --plan-version "${PLAN_VERSION}" \
  --parameters @"${APP_PARAMS_FILE}" \
  1>/dev/null

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${APP_NAME}"
echo "    Managed resource group: ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
