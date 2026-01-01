#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-veeam-vbma-mrg}"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Deleting resource group: $RG_NAME"
az group delete -n "$RG_NAME" --yes --no-wait

# best-effort delete of marketplace managed RG (don’t fail script)
if [[ -n "$VBMA_MRG_NAME" ]]; then
  echo "==> Deleting managed resource group (best-effort): $VBMA_MRG_NAME"
  az group delete -n "$VBMA_MRG_NAME" --yes --no-wait || true
fi

echo "==> Delete initiated."
