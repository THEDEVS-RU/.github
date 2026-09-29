#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required for actions/deploy-resolve but not found in PATH."
  exit 1
fi

validate_env_name() {
  local name="$1"
  local label="$2"
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "::error::Invalid $label '$name'. Environment names must match pattern ^[A-Za-z0-9._-]+$"
    exit 1
  fi
}

validate_prod_environments() {
  local prod_json="$1"
  if [ -n "$prod_json" ]; then
    if ! echo "$prod_json" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+\\z"))' >/dev/null 2>&1; then
      echo "::error::prod_environments must be a valid non-empty JSON array of strings matching ^[A-Za-z0-9._-]+$ (e.g. [\"prod-1\", \"prod-2\"]). Got: $prod_json"
      exit 1
    fi
  fi
}

validate_dev_environments() {
  local dev_json="$1"
  if [ -n "$dev_json" ]; then
    if ! echo "$dev_json" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+\\z"))' >/dev/null 2>&1; then
      echo "::error::dev_environments must be a valid non-empty JSON array of strings matching ^[A-Za-z0-9._-]+$ (e.g. [\"dev\", \"stage\"]). Got: $dev_json"
      exit 1
    fi
  fi
}

check_env_is_prod() {
  local env_name="$1"
  local prod_json="$2"
  if [ -n "$prod_json" ]; then
    if echo "$prod_json" | jq -e --arg env "$env_name" 'index($env) != null' >/dev/null 2>&1; then
      echo "true"
      return
    fi
  fi
  echo "false"
}

ACT="${ACTION:-}"
if [ -z "$ACT" ]; then
  echo "::error::Input 'action' is required and must be one of: environments, guard."
  exit 1
fi

validate_prod_environments "${PROD_ENVS:-}"
validate_dev_environments "${DEV_ENVS:-}"

case "$ACT" in
  environments)
    if [ -n "${INPUT_ENV:-}" ]; then
      validate_env_name "$INPUT_ENV" "input_environment"
      ENV_ARRAY=$(jq -cn --arg env "$INPUT_ENV" '[$env]')
    elif [ "${FALLBACK_PROD:-false}" = "true" ]; then
      if [ -z "${PROD_ENVS:-}" ]; then
        echo "::error::No target environment specified and PROD_ENVIRONMENTS variable is missing or empty."
        exit 1
      fi
      ENV_ARRAY=$(echo "$PROD_ENVS" | jq -c .)
    elif [ -n "${DEV_ENVS:-}" ]; then
      ENV_ARRAY=$(echo "$DEV_ENVS" | jq -c .)
    else
      DEF="${DEFAULT_ENV:-dev}"
      validate_env_name "$DEF" "default_environment"
      ENV_ARRAY=$(jq -cn --arg env "$DEF" '[$env]')
    fi

    # Ранний Prod Guard в джобе resolve
    if [ "${PROD_GUARD:-false}" = "true" ] && [ -n "${PROD_ENVS:-}" ]; then
      while IFS= read -r resolved_env; do
        if [ "$(check_env_is_prod "$resolved_env" "$PROD_ENVS")" = "true" ]; then
          echo "::error::Resolved environment '$resolved_env' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
          exit 1
        fi
      done < <(echo "$ENV_ARRAY" | jq -r '.[]')
    fi

    echo "environments=$(echo "$ENV_ARRAY" | jq -c .)" >> "$GITHUB_OUTPUT"
    ;;

  guard)
    if [ -z "${TARGET_ENV:-}" ]; then
      echo "::error::Input 'environment' is required for action 'guard'."
      exit 1
    fi
    validate_env_name "$TARGET_ENV" "environment"

    IS_PROD=$(check_env_is_prod "$TARGET_ENV" "${PROD_ENVS:-}")
    echo "is_prod=$IS_PROD" >> "$GITHUB_OUTPUT"

    if [ "$IS_PROD" = "true" ]; then
      echo "::error::'$TARGET_ENV' is a prod environment — prod deploys go through release.yml or redeploy.yml, not build.yml"
      exit 1
    fi
    ;;

  *)
    echo "::error::Input 'action' must be one of: environments, guard. Got: '$ACT'"
    exit 1
    ;;
esac
