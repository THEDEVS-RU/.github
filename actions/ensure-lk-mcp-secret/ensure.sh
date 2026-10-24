#!/usr/bin/env bash
set -euo pipefail

TARGET_NS="${TARGET_NS:-}"
if [ -z "$TARGET_NS" ]; then
  echo "::error::Input 'namespace' is required and cannot be empty." >&2
  exit 1
fi
SECRET_NAME="${SECRET_NAME:-thedevs-lk-mcp}"
TOKEN="${TOKEN:-}"
URL="${URL:-}"

if [ -z "$TOKEN" ]; then
  echo "::warning::THEDEVS_LK_MCP_TOKEN is empty. Skipping secret creation for $SECRET_NAME in $TARGET_NS."
  exit 0
fi

ARGS=(--from-literal=token="$TOKEN")
if [ -n "$URL" ]; then
  ARGS+=(--from-literal=url="$URL")
fi

kubectl create secret generic "$SECRET_NAME" "${ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -n "$TARGET_NS" -f -
echo "Kubernetes secret '$SECRET_NAME' successfully ensured in namespace '$TARGET_NS'."
