#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# using marketplace/vbazure.parameters.json (fallback) or env vars (preferred).

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

# Marketplace (prefer ENV, fallback to JSON)
VBMA_APP_NAME="${VBMA_APP_NAME:-}"                 # e.g. veeam-vbma-lab
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"                 # e.g. veeam-vbma-mrg (MUST NOT EXIST)
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"               # e.g. veeam
VBMA_OFFER="${VBMA_OFFER:-}"                       # e.g. azure_backup_free
VBMA_PLAN="${VBMA_PLAN:-}"                         # e.g. veeambackupazure_free_v6_0
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"         # e.g. 6.0.234

# Optional: marketplace "appParameters" payload (JSON object) as ENV string
# Example: VBMA_APP_PARAMETERS_JSON='{"someParam":{"value":"x"}}'  (or whatever the managed app expects)
VBMA_APP_PARAMETERS_JSON="${VBMA_APP_PARAMETERS_JSON:-}"

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
SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
APP_PARAMS_FILE=""

cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# If we need file fallback, validate tools + file exists
need_file_fallback=false
if [[ -z "${VBMA_APP_NAME}" || -z "${VBMA_MRG_NAME}" || -z "${VBMA_PUBLISHER}" || -z "${VBMA_OFFER}" || -z "${VBMA_PLAN}" || -z "${VBMA_PLAN_VERSION}" ]]; then
  need_file_fallback=true
fi

if [[ "${need_file_fallback}" == "true" ]]; then
  if [[ ! -f "${PARAM_FILE}" ]]; then
    echo "ERROR: Missing ${PARAM_FILE}"
    echo "       Provide VBMA_* env vars OR add marketplace/vbazure.parameters.json"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for marketplace deployment when using ${PARAM_FILE}."
    echo "       Install jq or set VBMA_* env vars."
    exit 1
  fi

  # Strip UTF-8 BOM if present (EF BB BF) to avoid: jq: Invalid numeric literal
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

  echo "==> Reading marketplace parameters from ${PARAM_FILE} (fallback)"
  : "${VBMA_PUBLISHER:=$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_OFFER:=$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_PLAN:=$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_PLAN_VERSION:=$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_APP_NAME:=$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_MRG_NAME:=$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")}"

  if [[ -z "${VBMA_APP_PARAMETERS_JSON}" ]]; then
    VBMA_APP_PARAMETERS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
  fi
else
  echo "==> Using marketplace parameters from environment (VBMA_*)"
fi

# Validate required VBMA values
if [[ -z "${VBMA_PUBLISHER}" || -z "${VBMA_OFFER}" || -z "${VBMA_PLAN}" || -z "${VBMA_PLAN_VERSION}" || -z "${VBMA_APP_NAME}" || -z "${VBMA_MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "       Need: VBMA_PUBLISHER, VBMA_OFFER, VBMA_PLAN, VBMA_PLAN_VERSION, VBMA_APP_NAME, VBMA_MRG_NAME"
  echo "       (Or provide them via ${PARAM_FILE})."
  exit 1
fi

# Managed RG must NOT exist. Azure will create it for the managed app.
if az group exists -n "${VBMA_MRG_NAME}" | grep -qi true; then
  echo "ERROR: Managed resource group '${VBMA_MRG_NAME}' already exists."
  echo "       For a Managed Application, Azure must create this RG."
  echo "       Delete it (or choose a new VBMA_MRG_NAME / parameters value) and re-run."
  echo ""
  echo "       Delete command:"
  echo "       az group delete -n \"${VBMA_MRG_NAME}\" --yes"
  exit 1
fi

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

echo "==> App RG: ${RG_NAME}"
echo "==> Managed RG: ${VBMA_MRG_NAME}"
echo "==> Managed RG id: ${MRG_ID}"

echo "==> Accepting marketplace terms (publisher=${VBMA_PUBLISHER}, offer=${VBMA_OFFER}, plan=${VBMA_PLAN})"
# Best-effort accept. (Different Azure CLI installs expose different commands.)
az term accept --publisher "${VBMA_PUBLISHER}" --product "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${VBMA_PUBLISHER}" --offer "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  true

# If appParameters JSON is provided and not empty, write it to a temp file.
# Note: az managedapp create expects the "parameters" object for the managed app, not ARM deploymentParameters wrapper.
if [[ -n "${VBMA_APP_PARAMETERS_JSON}" && "${VBMA_APP_PARAMETERS_JSON}" != "{}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to validate VBMA_APP_PARAMETERS_JSON."
    exit 1
  fi
  # Validate JSON (and normalize it). This prevents errors like: "Failed to parse string as JSON: {}}
  VBMA_APP_PARAMETERS_JSON="$(printf '%s' "${VBMA_APP_PARAMETERS_JSON}" | jq -c '.')"
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${VBMA_APP_PARAMETERS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${VBMA_APP_NAME}"
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}"
else
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}"
fi

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${VBMA_APP_NAME}"
echo "    Managed resource group: ${VBMA_MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
