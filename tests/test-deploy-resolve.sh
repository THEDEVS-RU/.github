#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_SCRIPT="$SCRIPT_DIR/../actions/deploy-resolve/resolve.sh"

if [ ! -x "$RESOLVE_SCRIPT" ]; then
  echo "Error: resolve.sh not found or not executable at $RESOLVE_SCRIPT"
  exit 1
fi

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local desc="$1"
  local expected_rc="$2"
  local expected_output="$3"
  shift 3
  # Remaining args are env vars in KEY=VALUE format

  TOTAL=$((TOTAL + 1))
  local out_file
  out_file=$(mktemp)

  local rc=0
  # Execute in clean subshell with explicit env
  (
    export GITHUB_OUTPUT="$out_file"
    export ACTION=""
    export INPUT_ENV=""
    export DEFAULT_ENV=""
    export FALLBACK_PROD=""
    export PROD_ENVS=""
    export TARGET_ENV=""
    export PROD_GUARD=""
    export HAS_K8S_CONFIG=""
    export HAS_SSH_KEY=""
    while [ $# -gt 0 ]; do
      export "$1"
      shift
    done
    bash "$RESOLVE_SCRIPT"
  ) >/dev/null 2>&1 || rc=$?

  local actual_output=""
  if [ -f "$out_file" ]; then
    actual_output=$(cat "$out_file")
    rm -f "$out_file"
  fi

  if [ "$rc" -ne "$expected_rc" ]; then
    echo "FAIL: $desc (expected exit code $expected_rc, got $rc)"
    FAILED=$((FAILED + 1))
    return
  fi

  if [ -n "$expected_output" ]; then
    if [[ "$actual_output" != *"$expected_output"* ]]; then
      echo "FAIL: $desc (expected output to contain '$expected_output', got '$actual_output')"
      FAILED=$((FAILED + 1))
      return
    fi
  fi

  echo "PASS: $desc"
  PASSED=$((PASSED + 1))
}

echo "=== Running tests for actions/deploy-resolve ==="

# 1. Missing action
run_test "1. Missing action -> error" 1 ""

# 2. Invalid action
run_test "2. Invalid action -> error" 1 "" ACTION="invalid_mode"

# 3. environments: default dev
run_test "3. environments: default call -> environments=[\"dev\"]" 0 'environments=["dev"]' \
  ACTION="environments"

# 4. environments: input_environment provided
run_test "4. environments: input_environment provided -> environments=[\"staging\"]" 0 'environments=["staging"]' \
  ACTION="environments" INPUT_ENV="staging"

# 5. environments: early Prod Guard blocks prod env
run_test "5. environments: early Prod Guard blocks prod env -> error" 1 "" \
  ACTION="environments" INPUT_ENV="prod-1" PROD_GUARD="true" PROD_ENVS='["prod-1","prod-2"]'

# 6. environments: fallback_to_prod with valid PROD_ENVIRONMENTS
run_test "6. environments: fallback_to_prod with valid PROD_ENVIRONMENTS -> environments=[\"prod-1\",\"prod-2\"]" 0 'environments=["prod-1","prod-2"]' \
  ACTION="environments" FALLBACK_PROD="true" PROD_ENVS='["prod-1","prod-2"]'

# 7. environments: fallback_to_prod with empty PROD_ENVIRONMENTS -> error
run_test "7. environments: fallback_to_prod with empty PROD_ENVIRONMENTS -> error" 1 "" \
  ACTION="environments" FALLBACK_PROD="true" PROD_ENVS=""

# 8. environments: invalid PROD_ENVIRONMENTS JSON syntax -> error
run_test "8a. environments: non-array PROD_ENVIRONMENTS -> error" 1 "" \
  ACTION="environments" PROD_ENVS='{"key":"value"}'
run_test "8b. environments: empty array PROD_ENVIRONMENTS -> error" 1 "" \
  ACTION="environments" PROD_ENVS='[]'
run_test "8c. environments: non-string element in PROD_ENVIRONMENTS -> error" 1 "" \
  ACTION="environments" PROD_ENVS='["prod-1", 123]'
run_test "8d. environments: invalid characters in PROD_ENVIRONMENTS element -> error" 1 "" \
  ACTION="environments" PROD_ENVS='["prod-1;rm -rf /"]'

# 9. Validation of invalid characters in environment name
run_test "9a. validate_env_name: semicolon injection -> error" 1 "" \
  ACTION="environments" INPUT_ENV="dev;rm -rf /"
run_test "9b. validate_env_name: spaces -> error" 1 "" \
  ACTION="environments" INPUT_ENV="dev env"
run_test "9c. validate_env_name: quotes -> error" 1 "" \
  ACTION="environments" INPUT_ENV='dev"test'
run_test "9d. validate_env_name: newline in input_environment -> error" 1 "" \
  ACTION="environments" INPUT_ENV=$'dev\n'
run_test "9e. validate_prod_environments: trailing newline in PROD_ENVIRONMENTS -> error" 1 "" \
  ACTION="environments" PROD_ENVS='["prod-1\n"]'

# 10. target: has_k8s_config = true -> mode=k8s, is_prod=false
run_test "10. target: has_k8s_config=true -> mode=k8s, is_prod=false" 0 $'is_prod=false\nmode=k8s' \
  ACTION="target" TARGET_ENV="dev" HAS_K8S_CONFIG="true" HAS_SSH_KEY="false"

# 11. target: has_k8s_config = false, has_ssh_key = true -> mode=ssh, is_prod=false
run_test "11. target: has_ssh_key=true -> mode=ssh, is_prod=false" 0 $'is_prod=false\nmode=ssh' \
  ACTION="target" TARGET_ENV="dev" HAS_K8S_CONFIG="false" HAS_SSH_KEY="true"

# 12. target: both flags false -> error
run_test "12. target: both flags false -> error" 1 "" \
  ACTION="target" TARGET_ENV="dev" HAS_K8S_CONFIG="false" HAS_SSH_KEY="false"

# 13. target: prod env handling
run_test "13a. target: prod env with prod_guard=true -> error" 1 "" \
  ACTION="target" TARGET_ENV="prod-1" PROD_GUARD="true" PROD_ENVS='["prod-1","prod-2"]' HAS_K8S_CONFIG="true"
run_test "13b. target: prod env with prod_guard=false -> mode=k8s, is_prod=true" 0 $'is_prod=true\nmode=k8s' \
  ACTION="target" TARGET_ENV="prod-1" PROD_GUARD="false" PROD_ENVS='["prod-1","prod-2"]' HAS_K8S_CONFIG="true"

# Standalone guard action
run_test "14a. guard: non-prod env -> is_prod=false" 0 'is_prod=false' \
  ACTION="guard" TARGET_ENV="dev" PROD_ENVS='["prod-1"]'
run_test "14b. guard: prod env -> error and is_prod=true" 1 'is_prod=true' \
  ACTION="guard" TARGET_ENV="prod-1" PROD_ENVS='["prod-1"]'

echo "=== Test Results: $PASSED / $TOTAL passed ($FAILED failed) ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
