#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# using env vars (preferred) or marketplace/vbazure.parameters.json as fallback.

# ---- Required env vars (or edit defaults below) ----
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-switzerlandnorth}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"

ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"   # required unless you edit to prompt securely
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# Marketplace toggle
DEPLOY_VBMA="${DEPLOY_VBMA:-false}"  # true/false

# Marketplace values (env preferred)
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"

# Optional: managed app parameters (JSON object) provided via env
# Example: export VBMA_APP_PARAMETERS_JSON='{"someParam":{"value":"x"}}'
VBMA_APP_PARAMETERS_JSON="${VBMA_APP_PARAMETERS_JSON:-}"

# Fallback parameter file (if env vars not set)
PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"

STATE_FILE="${REPO_ROOT}/.vbma.state"

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

# Use the subscription id Azure CLI is actually using (avoids subtle mismatches)
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "==> Azure context: subscription=${SUB_ID}, tenant=${TENANT_ID}"

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
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for marketplace deployment. Install jq or set DEPLOY_VBMA=false."
  exit 1
fi

# Create a sanitized temp copy of the param file if it exists (fixes UTF-8 BOM issues)
SANITIZED_PARAM_FILE=""
APP_PARAMS_FILE=""

cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -f "${PARAM_FILE}" ]]; then
  SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
  # Strip UTF-8 BOM if present (EF BB BF)
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"
fi

# Helper: read value from env first, else from param file
read_param() {
  local env_val="$1"
  local jq_expr="$2"
  if [[ -n "${env_val}" ]]; then
    printf '%s' "${env_val}"
    return 0
  fi
  if [[ -n "${SANITIZED_PARAM_FILE}" ]]; then
    jq -r "${jq_expr}" "${SANITIZED_PARAM_FILE}"
    return 0
  fi
  printf ''
}

echo "==> Reading marketplace parameters (env preferred${PARAM_FILE:+, file fallback: ${PARAM_FILE}})"
PUBLISHER="$(read_param "${VBMA_PUBLISHER}" '.parameters.publisher.value // empty')"
OFFER="$(read_param "${VBMA_OFFER}" '.parameters.offer.value // empty')"
PLAN="$(read_param "${VBMA_PLAN}" '.parameters.plan.value // empty')"
PLAN_VERSION="$(read_param "${VBMA_PLAN_VERSION}" '.parameters.planVersion.value // empty')"
APP_NAME="$(read_param "${VBMA_APP_NAME}" '.parameters.managedApplicationName.value // empty')"
MRG_NAME="$(read_param "${VBMA_MRG_NAME}" '.parameters.managedResourceGroupName.value // empty')"

if [[ -z "${PUBLISHER}" || -z "${OFFER}" || -z "${PLAN}" || -z "${PLAN_VERSION}" || -z "${APP_NAME}" || -z "${MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "Need: VBMA_PUBLISHER, VBMA_OFFER, VBMA_PLAN, VBMA_PLAN_VERSION, VBMA_APP_NAME, VBMA_MRG_NAME"
  echo "You can set them as env vars or provide them in ${PARAM_FILE}"
  exit 1
fi

# IMPORTANT: Managed Application requires that the managed RG does NOT already exist.
# Azure will create it. If it exists, generate a unique name automatically.
if az group exists -n "${MRG_NAME}" >/dev/null 2>&1; then
  if [[ "$(az group exists -n "${MRG_NAME}" -o tsv)" == "true" ]]; then
    OLD="${MRG_NAME}"
    MRG_NAME="${MRG_NAME}-$(date +%Y%m%d%H%M%S)"
    echo "==> NOTE: Managed RG '${OLD}' already exists in subscription ${SUB_ID}."
    echo "==> Using a new Managed RG name instead: ${MRG_NAME}"
  fi
fi

MRG_ID="/subscriptions/${SUB_ID}/resourceGroups/${MRG_NAME}"

echo "==> App RG: ${RG_NAME}"
echo "==> Managed RG: ${MRG_NAME}"
echo "==> Managed RG id: ${MRG_ID}"

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN})"
# az term accept does not take --version; best-effort accept for different CLI versions
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Build app parameters payload:
# - Prefer VBMA_APP_PARAMETERS_JSON if set
# - Else use .parameters.appParameters.value from the param file if present
APP_PARAMS_JSON="{}"
if [[ -n "${VBMA_APP_PARAMETERS_JSON}" ]]; then
  APP_PARAMS_JSON="${VBMA_APP_PARAMETERS_JSON}"
elif [[ -n "${SANITIZED_PARAM_FILE}" ]]; then
  APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
fi

# If app params are non-empty, write to file and pass with --parameters @file.
# This avoids shell quoting / JSON parsing issues in az.
if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}" \
    1>/dev/null
else
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}" \
    1>/dev/null
fi

# Save state so destroy.sh can clean up even if params/env change later
cat > "${STATE_FILE}" <<EOF
APP_RG_NAME=${RG_NAME}
APP_NAME=${APP_NAME}
MRG_NAME=${MRG_NAME}
SUBSCRIPTION_ID=${SUB_ID}
EOF

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${APP_NAME}"
echo "    App RG: ${RG_NAME}"
echo "    Managed RG: ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
echo "    State file: ${STATE_FILE}"
