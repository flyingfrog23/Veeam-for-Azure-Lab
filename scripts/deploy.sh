#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app.

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

# Marketplace values can come from env vars; if empty, we fall back to the marketplace params file.
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"
# Optional: raw JSON for app parameters (if you prefer env instead of file)
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
SANITIZED_PARAM_FILE=""
APP_PARAMS_FILE=""

cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# If any marketplace vars are missing, load the params file (and sanitize BOM for jq)
if [[ -z "${VBMA_PUBLISHER}" || -z "${VBMA_OFFER}" || -z "${VBMA_PLAN}" || -z "${VBMA_PLAN_VERSION}" || -z "${VBMA_APP_NAME}" || -z "${VBMA_MRG_NAME}" ]]; then
  if [[ ! -f "${PARAM_FILE}" ]]; then
    echo "ERROR: Missing ${PARAM_FILE}"
    echo "       Either create it, or set all VBMA_* env vars (VBMA_PUBLISHER/OFFER/PLAN/PLAN_VERSION/APP_NAME/MRG_NAME)."
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for marketplace deployment when using ${PARAM_FILE}."
    echo "       Install jq OR set the VBMA_* env vars and VBMA_APP_PARAMS_JSON, then retry."
    exit 1
  fi

  # jq can fail with "Invalid numeric literal" if the file has a UTF-8 BOM.
  SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

  echo "==> Reading marketplace parameters from ${PARAM_FILE}"

  # Fill only missing values from file; env vars win.
  : "${VBMA_PUBLISHER:=$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_OFFER:=$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_PLAN:=$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_PLAN_VERSION:=$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_APP_NAME:=$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")}"
  : "${VBMA_MRG_NAME:=$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")}"

  # appParameters from file only if env var not set
  if [[ -z "${VBMA_APP_PARAMS_JSON}" ]]; then
    VBMA_APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
  fi
fi

# Validate required marketplace values
if [[ -z "${VBMA_PUBLISHER}" || -z "${VBMA_OFFER}" || -z "${VBMA_PLAN}" || -z "${VBMA_PLAN_VERSION}" || -z "${VBMA_APP_NAME}" || -z "${VBMA_MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "       Need: VBMA_PUBLISHER, VBMA_OFFER, VBMA_PLAN, VBMA_PLAN_VERSION, VBMA_APP_NAME, VBMA_MRG_NAME"
  exit 1
fi

# Managed Apps REQUIRE the managed resource group be DIFFERENT from the app's resource group.
# If you try to reuse RG_NAME, Azure will reject it and/or you'll get invalid RG id errors.
if [[ "${VBMA_MRG_NAME}" == "${RG_NAME}" ]]; then
  echo "==> Managed resource group name equals RG_NAME; adjusting to keep them separate."
  VBMA_MRG_NAME="${RG_NAME}-mrg"
  echo "    Using managed resource group name: ${VBMA_MRG_NAME}"
fi

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

echo "==> Accepting marketplace terms (publisher=${VBMA_PUBLISHER}, offer=${VBMA_OFFER}, plan=${VBMA_PLAN})"
# Best-effort accept: different Az CLI installs support different commands.
az term accept --publisher "${VBMA_PUBLISHER}" --product "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${VBMA_PUBLISHER}" --offer "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Prepare app parameters file if provided (must be plain JSON object, not deploymentParameters wrapper).
# If VBMA_APP_PARAMS_JSON is empty, treat as {}.
VBMA_APP_PARAMS_JSON="${VBMA_APP_PARAMS_JSON:-{}}"
if [[ "${VBMA_APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${VBMA_APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${VBMA_APP_NAME}"
echo "    App RG: ${RG_NAME}"
echo "    Managed RG: ${VBMA_MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"

# IMPORTANT:
# - The managed application "shell" is created in RG_NAME (your lab RG).
# - Azure will create the managed resource group identified by MRG_ID (must not be the same as RG_NAME).
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    -m "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}" \
    1>/dev/null
else
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    -m "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}" \
    1>/dev/null
fi

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app (shell): ${VBMA_APP_NAME} (in RG ${RG_NAME})"
echo "    Managed resource group: ${VBMA_MRG_NAME} (created/owned by the managed app)"
