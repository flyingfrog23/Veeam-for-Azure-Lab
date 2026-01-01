#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Paths
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------
# Load .env
# -----------------------------
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# -----------------------------
# Required / defaults
# -----------------------------
: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"

LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"
ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# -----------------------------
# Azure context
# -----------------------------
az account set --subscription "${SUBSCRIPTION_ID}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

# -----------------------------
# Create RG
# -----------------------------
echo "==> Creating resource group: ${RG_NAME} (${LOCATION})"
az group create \
  --name "${RG_NAME}" \
  --location "${LOCATION}" \
  1>/dev/null

# -----------------------------
# Deploy baseline
# -----------------------------
echo "==> Deploying baseline lab (Bicep)"
az deployment group create \
  --resource-group "${RG_NAME}" \
  --name "baseline-$(date +%Y%m%d%H%M%S)" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters \
    prefix="${PREFIX}" \
    location="${LOCATION}" \
    adminUsername="${ADMIN_USERNAME}" \
    adminPassword="${ADMIN_PASSWORD}" \
    allowedRdpSource="${ALLOWED_RDP_SOURCE}" \
  1>/dev/null

echo "==> Baseline lab deployed successfully."
