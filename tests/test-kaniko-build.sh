#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_FILE="${SCRIPT_DIR}/../actions/kaniko-build/action.yml"

if [ ! -f "$ACTION_FILE" ]; then
  echo "Error: action.yml not found at $ACTION_FILE" >&2
  exit 1
fi

echo "=== TD-2197: Contract Tests for actions/kaniko-build ==="

TEST_DIR=$(mktemp -d -t td2197-kaniko-tests-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

BIN_DIR="$TEST_DIR/bin"
mkdir -p "$BIN_DIR"
EXTRACTED_SCRIPT="$TEST_DIR/kaniko-run.sh"
CAPTURED_YAML="$TEST_DIR/pod.yaml"

# 1. Extract run: script from action.yml
awk '
  /^      run: \|/ { in_run=1; next }
  in_run {
    if (/^        /) {
      print substr($0, 9)
    } else if (/^[[:space:]]*$/) {
      print ""
    } else {
      exit
    }
  }
' "$ACTION_FILE" > "$EXTRACTED_SCRIPT"
chmod +x "$EXTRACTED_SCRIPT"

if [ ! -s "$EXTRACTED_SCRIPT" ]; then
  echo "Error: Failed to extract run script from $ACTION_FILE" >&2
  exit 1
fi

# 2. Setup mock kubectl and sleep
cat > "$BIN_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash

if [ -n "${KUBECTL_ARGV_LOG:-}" ]; then
  echo "kubectl $@" >> "$KUBECTL_ARGV_LOG"
fi

cmd=""
secret_name=""
pod_name=""

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  arg="${args[i]}"
  if [ "$arg" = "create" ] && [ "${args[i+1]:-}" = "secret" ]; then
    cmd="create_secret"
    secret_name="${args[i+3]:-}"
  elif [ "$arg" = "delete" ] && [ "${args[i+1]:-}" = "secret" ]; then
    cmd="delete_secret"
    secret_name="${args[i+2]:-}"
  elif [ "$arg" = "patch" ] && [ "${args[i+1]:-}" = "secret" ]; then
    cmd="patch_secret"
    secret_name="${args[i+2]:-}"
  elif [ "$arg" = "get" ] && [ "${args[i+1]:-}" = "secret" ]; then
    cmd="get_secret"
    secret_name="${args[i+2]:-}"
  elif [ "$arg" = "get" ] && [ "${args[i+1]:-}" = "pod" ]; then
    cmd="get_pod"
    pod_name="${args[i+2]:-}"
  elif [ "$arg" = "apply" ]; then
    cmd="apply"
  fi
done

if [ "$cmd" = "create_secret" ]; then
  for arg in "$@"; do
    if [[ "$arg" =~ ^--from-file=(.*) ]]; then
      file_spec="${BASH_REMATCH[1]}"
      file_path="${file_spec#*=}"
      if [ ! -f "$file_path" ]; then
        echo "Error from server: from-file path '$file_path' does not exist" >&2
        exit 1
      fi
      if [ -n "${MOCK_SAVED_PROP_FILE:-}" ]; then
        cp "$file_path" "$MOCK_SAVED_PROP_FILE"
      fi
    fi
  done
  if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
    echo "create secret generic $secret_name" >> "$KUBECTL_CALLS_LOG"
  fi
  if [ "${MOCK_SECRET_CREATE_FORBIDDEN:-0}" -eq 1 ]; then
    echo "Error from server (Forbidden): secrets is forbidden: User \"system:serviceaccount:test-ns:builder-sa\" cannot create resource \"secrets\" in API group \"\" in the namespace \"test-ns\"" >&2
    exit 1
  fi
  if [ "${MOCK_SECRET_CREATE_TRANSIENT:-0}" -eq 1 ]; then
    echo "Error from server: connection reset by peer" >&2
    exit 1
  fi
  echo "secret/$secret_name created"
  exit 0
elif [ "$cmd" = "apply" ]; then
  STDIN_DATA=$(cat)
  if printf '%s' "$STDIN_DATA" | grep -F -q 'kind: Secret'; then
    if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
      echo "apply secret" >> "$KUBECTL_CALLS_LOG"
    fi
    echo "secret/mock-secret created"
    exit 0
  fi
  if printf '%s' "$STDIN_DATA" | grep -F -q 'kind: Pod'; then
    if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
      echo "apply pod" >> "$KUBECTL_CALLS_LOG"
    fi
    if [ "${MOCK_POD_APPLY_FAIL:-0}" -eq 1 ]; then
      echo "Error from server: Internal error applying pod" >&2
      exit 1
    fi
    if [ -n "${KUBECTL_CAPTURED_YAML:-}" ]; then
      printf '%s\n' "$STDIN_DATA" > "$KUBECTL_CAPTURED_YAML"
    fi
    echo "pod/kaniko-mock created"
    exit 0
  fi
  if [ -n "${KUBECTL_CAPTURED_YAML:-}" ]; then
    printf '%s\n' "$STDIN_DATA" > "$KUBECTL_CAPTURED_YAML"
  fi
  echo "created"
  exit 0
elif [ "$cmd" = "delete_secret" ]; then
  if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
    echo "delete secret $secret_name" >> "$KUBECTL_CALLS_LOG"
  fi
  echo "secret \"$secret_name\" deleted"
  exit 0
elif [ "$cmd" = "patch_secret" ]; then
  if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
    echo "patch secret $@" >> "$KUBECTL_CALLS_LOG"
  fi
  echo "secret/$secret_name patched"
  exit 0
elif [ "$cmd" = "get_secret" ]; then
  if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
    echo "get secret $secret_name" >> "$KUBECTL_CALLS_LOG"
  fi
  if [ -n "${MOCK_GET_SECRET_NOT_FOUND:-}" ] && [ "$secret_name" = "$MOCK_GET_SECRET_NOT_FOUND" ]; then
    echo "Error from server (NotFound): secrets \"$secret_name\" not found" >&2
    exit 1
  fi
  exit 0
elif [ "$cmd" = "get_pod" ]; then
  for arg in "$@"; do
    if [[ "$arg" =~ jsonpath.*status\.phase ]]; then
      echo "${MOCK_POD_PHASE:-Succeeded}"
      exit 0
    fi
    if [[ "$arg" =~ jsonpath.*metadata\.uid ]]; then
      if [ -n "${KUBECTL_CALLS_LOG:-}" ]; then
        echo "get pod uid" >> "$KUBECTL_CALLS_LOG"
      fi
      echo "mock-pod-uid-42"
      exit 0
    fi
  done
  exit 0
fi

for arg in "$@"; do
  if [ "$arg" = "-f" ] || [ "$arg" = "--filename" ]; then
    if [ -n "${KUBECTL_CAPTURED_YAML:-}" ]; then
      cat > "$KUBECTL_CAPTURED_YAML"
    else
      cat > /dev/null
    fi
    echo "pod/kaniko-mock created"
    exit 0
  fi
  if [[ "$arg" =~ jsonpath.*status\.phase ]]; then
    echo "${MOCK_POD_PHASE:-Succeeded}"
    exit 0
  fi
done
exit 0
EOF
chmod +x "$BIN_DIR/kubectl"

cat > "$BIN_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/sleep"

TOTAL=0
PASSED=0
FAILED=0

# Helper to execute the extracted script in an isolated subshell
ACTION_RC=0
ACTION_LOG=""

run_action() {
  local output_file="$TEST_DIR/action.log"
  rm -f "$CAPTURED_YAML" "$output_file" "$TEST_DIR/kubectl_calls.log" "$TEST_DIR/kubectl_argv.log" "$TEST_DIR/saved_prop_file"
  local rc=0
  (
    export PATH="$BIN_DIR:$PATH"
    export KUBECTL_CAPTURED_YAML="$CAPTURED_YAML"
    export KUBECTL_CALLS_LOG="$TEST_DIR/kubectl_calls.log"
    export KUBECTL_ARGV_LOG="$TEST_DIR/kubectl_argv.log"
    export MOCK_SAVED_PROP_FILE="$TEST_DIR/saved_prop_file"
    export MOCK_SECRET_CREATE_FORBIDDEN="0"
    export MOCK_SECRET_CREATE_TRANSIENT="0"
    export MOCK_POD_APPLY_FAIL="0"
    export MOCK_GET_SECRET_NOT_FOUND=""
    export POD_NAME="kaniko-test-1-1"
    export IMAGE="registry.thedevs.ru/test-image"
    export TAG="test-tag"
    export NS="test-ns"
    export GIT_TOKEN="token123"
    export SECRET="test-secret"
    export CACHE_PVC="test-pvc"
    export INPUT_REPO="test-org/test-repo"
    export INPUT_BRANCH="dev"
    export INPUT_CACHE_REPO=""
    export INPUT_BUILD_TIMEOUT="7200"
    export INPUT_DOCKERFILE="Dockerfile"
    export CLAUDE_CLI_VERSION=""
    export DOCKERHUB_USERNAME=""
    export DOCKERHUB_TOKEN=""
    export REGISTRY_TOKEN=""
    export REGISTRY_USERNAME="thedevsru"
    export REGISTRY_SERVER="registry.thedevs.ru"
    export INSECURE="true"
    export INSECURE_PULL="true"
    export IMAGE_FS_EXTRACT_RETRY="0"
    export INPUT_CPU_LIMIT="16000m"
    export INPUT_EXTRA_TAGS=""
    export INPUT_BUILD_ARGS=""
    export INPUT_GRADLE_SECRET=""
    export INPUT_GRADLE_USERNAME=""
    export INPUT_GRADLE_PASSWORD=""
    export CACHEBUST="1-1"
    export CALLER_REPO="test-org/test-repo"
    export CALLER_REF="dev"
    while [ $# -gt 0 ]; do
      export "$1"
      shift
    done
    bash "$EXTRACTED_SCRIPT"
  ) >"$output_file" 2>&1 || rc=$?

  ACTION_RC=$rc
  ACTION_LOG=$(cat "$output_file" 2>/dev/null || true)
}

get_kubectl_calls() {
  cat "$TEST_DIR/kubectl_calls.log" 2>/dev/null || true
}

get_kubectl_argv() {
  cat "$TEST_DIR/kubectl_argv.log" 2>/dev/null || true
}

get_kaniko_resources() {
  if [ ! -f "$CAPTURED_YAML" ]; then
    echo ""
    return
  fi
  sed -n '/- name: kaniko/,/volumeMounts:/p' "$CAPTURED_YAML" | sed -n '/resources:/,/volumeMounts:/p'
}

get_kaniko_limits() {
  local res
  res=$(get_kaniko_resources)
  echo "$res" | sed -n '/limits:/,/volumeMounts:/p'
}

get_kaniko_args() {
  if [ ! -f "$CAPTURED_YAML" ]; then
    echo ""
    return
  fi
  sed -n '/- name: kaniko/,/resources:/p' "$CAPTURED_YAML" | sed -n '/args:/,/resources:/p'
}

assert_contains() {
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | grep -F -q -e "$pattern"
}

assert_not_contains() {
  local text="$1"
  local pattern="$2"
  ! printf '%s\n' "$text" | grep -F -q -e "$pattern"
}

count_matches() {
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | grep -F -c -e "$pattern" || true
}

test_pass() {
  local desc="$1"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
  echo "PASS: $desc"
}

test_fail() {
  local desc="$1"
  local reason="$2"
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  echo "FAIL: $desc ($reason)"
}

# ==============================================================================
# 1. cpu_limit tests
# ==============================================================================

# 1.1 Default cpu_limit (16000m)
run_action INPUT_CPU_LIMIT=""
lim=$(get_kaniko_limits)
res=$(get_kaniko_resources)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$lim" 'cpu: "16000m"' && \
   assert_contains "$lim" 'memory: "8Gi"' && \
   assert_contains "$res" 'cpu: "1000m"'; then
  test_pass "1.1 cpu_limit default -> limits.cpu=\"16000m\", limits.memory=\"8Gi\", requests.cpu=\"1000m\""
else
  test_fail "1.1 cpu_limit default" "RC=$ACTION_RC, limits='$lim'"
fi

# 1.2 Explicit integer cpu_limit (8)
run_action INPUT_CPU_LIMIT="8"
lim=$(get_kaniko_limits)
res=$(get_kaniko_resources)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$lim" 'cpu: "8"' && \
   assert_contains "$lim" 'memory: "8Gi"' && \
   assert_contains "$res" 'cpu: "1000m"'; then
  test_pass "1.2 cpu_limit='8' -> limits.cpu=\"8\", limits.memory=\"8Gi\", requests.cpu=\"1000m\""
else
  test_fail "1.2 cpu_limit='8'" "RC=$ACTION_RC, limits='$lim'"
fi

# 1.3 Removal of cpu limit on '0'
run_action INPUT_CPU_LIMIT="0"
lim=$(get_kaniko_limits)
res=$(get_kaniko_resources)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$lim" 'memory: "8Gi"' && \
   assert_contains "$res" 'cpu: "1000m"' && \
   ! echo "$lim" | grep -E -q 'cpu:'; then
  test_pass "1.3 cpu_limit='0' -> no cpu line in limits, memory: 8Gi preserved"
else
  test_fail "1.3 cpu_limit='0'" "RC=$ACTION_RC, limits='$lim'"
fi

# 1.4 Removal of cpu limit on '0m'
run_action INPUT_CPU_LIMIT="0m"
lim=$(get_kaniko_limits)
res=$(get_kaniko_resources)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$lim" 'memory: "8Gi"' && \
   assert_contains "$res" 'cpu: "1000m"' && \
   ! echo "$lim" | grep -E -q 'cpu:'; then
  test_pass "1.4 cpu_limit='0m' -> no cpu line in limits, memory: 8Gi preserved"
else
  test_fail "1.4 cpu_limit='0m'" "RC=$ACTION_RC, limits='$lim'"
fi

# 1.5 Removal of cpu limit on 'none'
run_action INPUT_CPU_LIMIT="none"
lim=$(get_kaniko_limits)
res=$(get_kaniko_resources)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$lim" 'memory: "8Gi"' && \
   assert_contains "$res" 'cpu: "1000m"' && \
   ! echo "$lim" | grep -E -q 'cpu:'; then
  test_pass "1.5 cpu_limit='none' -> no cpu line in limits, memory: 8Gi preserved"
else
  test_fail "1.5 cpu_limit='none'" "RC=$ACTION_RC, limits='$lim'"
fi

# 1.6 Removal of cpu limit on 'None'
run_action INPUT_CPU_LIMIT="None"
lim=$(get_kaniko_limits)
res=$(get_kaniko_resources)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$lim" 'memory: "8Gi"' && \
   assert_contains "$res" 'cpu: "1000m"' && \
   ! echo "$lim" | grep -E -q 'cpu:'; then
  test_pass "1.6 cpu_limit='None' -> no cpu line in limits, memory: 8Gi preserved"
else
  test_fail "1.6 cpu_limit='None'" "RC=$ACTION_RC, limits='$lim'"
fi

# 1.7 Fail-fast: cpu_limit less than requests.cpu (500m)
run_action INPUT_CPU_LIMIT="500m"
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'cannot be less than requests.cpu'; then
  test_pass "1.7 cpu_limit='500m' -> fail-fast (rc!=0, ::error:: cannot be less than requests.cpu)"
else
  test_fail "1.7 cpu_limit='500m'" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 1.8 Fail-fast: multiline cpu_limit ("500m\n8")
run_action INPUT_CPU_LIMIT=$'500m\n8'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Invalid cpu_limit format'; then
  test_pass "1.8 cpu_limit multiline -> fail-fast (rc!=0, ::error:: Invalid cpu_limit format)"
else
  test_fail "1.8 cpu_limit multiline" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 1.9 Fail-fast: overflow cpu_limit (99999999999999999999)
run_action INPUT_CPU_LIMIT="99999999999999999999"
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Invalid cpu_limit format'; then
  test_pass "1.9 cpu_limit overflow -> fail-fast (rc!=0, ::error:: Invalid cpu_limit format)"
else
  test_fail "1.9 cpu_limit overflow" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 1.10 Fail-fast: non-numeric cpu_limit (abc)
run_action INPUT_CPU_LIMIT="abc"
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Invalid cpu_limit format'; then
  test_pass "1.10 cpu_limit='abc' -> fail-fast (rc!=0, ::error:: Invalid cpu_limit format)"
else
  test_fail "1.10 cpu_limit='abc'" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# ==============================================================================
# 2. extra_tags tests
# ==============================================================================

# 2.1 extra_tags: 'latest, d-1' -> generates additional destinations
run_action INPUT_EXTRA_TAGS="latest, d-1"
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" '--destination=registry.thedevs.ru/test-image:test-tag' && \
   assert_contains "$args" '--destination=registry.thedevs.ru/test-image:latest' && \
   assert_contains "$args" '--destination=registry.thedevs.ru/test-image:d-1'; then
  test_pass "2.1 extra_tags: 'latest, d-1' -> two additional --destination flags generated"
else
  test_fail "2.1 extra_tags: 'latest, d-1'" "RC=$ACTION_RC, args='$args'"
fi

# 2.2 extra_tags: whitespace and newline separation
run_action INPUT_EXTRA_TAGS=$'v1.0.0\tv1.0.1\n v1.0.2 '
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" '--destination=registry.thedevs.ru/test-image:v1.0.0' && \
   assert_contains "$args" '--destination=registry.thedevs.ru/test-image:v1.0.1' && \
   assert_contains "$args" '--destination=registry.thedevs.ru/test-image:v1.0.2'; then
  test_pass "2.2 extra_tags: whitespace and newline separated tags parsed correctly"
else
  test_fail "2.2 extra_tags: whitespace/newline" "RC=$ACTION_RC, args='$args'"
fi

# 2.3 extra_tags: invalid tag format (bad/tag)
run_action INPUT_EXTRA_TAGS="bad/tag"
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" "Invalid docker tag format in extra_tags: 'bad/tag'"; then
  test_pass "2.3 extra_tags: invalid tag 'bad/tag' -> error"
else
  test_fail "2.3 extra_tags: invalid tag 'bad/tag'" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# ==============================================================================
# 3. build_args tests
# ==============================================================================

# 3.1 Dollar escaping ($ -> $$) in build_args
run_action INPUT_BUILD_ARGS=$'SALT=ab$$cd\nVAR=$(X)'
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" '--build-arg=SALT=ab$$$$cd' && \
   assert_contains "$args" '--build-arg=VAR=$$(X)'; then
  test_pass "3.1 build_args dollar escaping: SALT=ab\$\$cd -> ab\$\$\$\$cd, \$(X) -> \$\$(X)"
else
  test_fail "3.1 build_args dollar escaping" "RC=$ACTION_RC, args='$args'"
fi

# 3.2 Apostrophe and spaces preservation
run_action INPUT_BUILD_ARGS="GREETING=hello 'world' 123"
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" "--build-arg=GREETING=hello 'world' 123"; then
  test_pass "3.2 build_args: apostrophes and spaces preserved"
else
  test_fail "3.2 build_args: apostrophes and spaces preserved" "RC=$ACTION_RC, args='$args'"
fi

# 3.3 Comments starting with # ignored
run_action INPUT_BUILD_ARGS=$'# This is a comment\nVALID_KEY=valid_val'
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" '--build-arg=VALID_KEY=valid_val' && \
   assert_not_contains "$args" 'This is a comment'; then
  test_pass "3.3 build_args: comments starting with # ignored"
else
  test_fail "3.3 build_args comments" "RC=$ACTION_RC, args='$args'"
fi

# 3.4 Error on double quotes in build_args
run_action INPUT_BUILD_ARGS='FOO="bar"'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Quotes (") and backslashes (\) are forbidden'; then
  test_pass "3.4 build_args: double quotes rejected with error"
else
  test_fail "3.4 build_args: double quotes rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 3.5 Error on backslash in build_args
run_action INPUT_BUILD_ARGS='FOO=bar\baz'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Quotes (") and backslashes (\) are forbidden'; then
  test_pass "3.5 build_args: backslash rejected with error"
else
  test_fail "3.5 build_args: backslash rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 3.6 Error on reserved CACHEBUST key in build_args
run_action INPUT_BUILD_ARGS='CACHEBUST=override'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" "build_args key 'CACHEBUST' is reserved"; then
  test_pass "3.6 build_args: CACHEBUST reserved key rejected with error"
else
  test_fail "3.6 build_args: CACHEBUST reserved key rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 3.7 Error on duplicate key in build_args
run_action INPUT_BUILD_ARGS=$'FOO=1\nFOO=2'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" "Duplicate build_arg key 'FOO' in build_args"; then
  test_pass "3.7 build_args: duplicate key 'FOO' rejected with error"
else
  test_fail "3.7 build_args: duplicate key rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 3.8 Error on invalid key syntax in build_args (starts with digit)
run_action INPUT_BUILD_ARGS='123=invalid'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Must match KEY=VALUE syntax'; then
  test_pass "3.8 build_args: invalid key '123' rejected with error"
else
  test_fail "3.8 build_args: invalid key rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 3.9 Error on missing equals sign in build_args
run_action INPUT_BUILD_ARGS='INVALID_LINE_WITHOUT_EQUALS'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Must match KEY=VALUE syntax'; then
  test_pass "3.9 build_args: missing equals sign rejected with error"
else
  test_fail "3.9 build_args: missing equals sign rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# ==============================================================================
# 4. claude_cli_version and interaction tests
# ==============================================================================

# 4.1 Precedence of CLAUDE_CLI_VERSION in build_args over claude_cli_version
run_action CLAUDE_CLI_VERSION="0.2.0" INPUT_BUILD_ARGS='CLAUDE_CLI_VERSION=0.3.0'
args=$(get_kaniko_args)
claude_count=$(count_matches "$args" '--build-arg=CLAUDE_CLI_VERSION=')
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$ACTION_LOG" '::warning::CLAUDE_CLI_VERSION provided via both claude_cli_version and build_args. build_args takes precedence.' && \
   assert_contains "$args" '--build-arg=CLAUDE_CLI_VERSION=0.3.0' && \
   assert_not_contains "$args" '0.2.0' && \
   [ "$claude_count" -eq 1 ]; then
  test_pass "4.1 CLAUDE_CLI_VERSION precedence: build_args wins, warning emitted, exactly 1 build-arg without duplicate"
else
  test_fail "4.1 CLAUDE_CLI_VERSION precedence" "RC=$ACTION_RC, count=$claude_count, log='$ACTION_LOG', args='$args'"
fi

# 4.2 Standalone claude_cli_version without build_args
run_action CLAUDE_CLI_VERSION="0.2.0" INPUT_BUILD_ARGS=""
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" '--build-arg=CLAUDE_CLI_VERSION=0.2.0'; then
  test_pass "4.2 claude_cli_version standalone -> --build-arg=CLAUDE_CLI_VERSION=0.2.0"
else
  test_fail "4.2 claude_cli_version standalone" "RC=$ACTION_RC, args='$args'"
fi

# 4.3 Dollar escaping in standalone claude_cli_version
run_action CLAUDE_CLI_VERSION='$(VERSION)' INPUT_BUILD_ARGS=""
args=$(get_kaniko_args)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$args" '--build-arg=CLAUDE_CLI_VERSION=$$(VERSION)'; then
  test_pass "4.3 claude_cli_version dollar escaping: \$(VERSION) -> \$\$(VERSION)"
else
  test_fail "4.3 claude_cli_version dollar escaping" "RC=$ACTION_RC, args='$args'"
fi

# 4.4 Error on quote in claude_cli_version
run_action CLAUDE_CLI_VERSION='0.2.0"'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Invalid characters in claude_cli_version'; then
  test_pass "4.4 claude_cli_version: quote rejected with error"
else
  test_fail "4.4 claude_cli_version: quote rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 4.5 Error on backslash in claude_cli_version
run_action CLAUDE_CLI_VERSION='0.2.0\foo'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Invalid characters in claude_cli_version'; then
  test_pass "4.5 claude_cli_version: backslash rejected with error"
else
  test_fail "4.5 claude_cli_version: backslash rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 4.6 Error on newline in claude_cli_version
run_action CLAUDE_CLI_VERSION=$'0.2.0\nfoo'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" '::error::' && \
   assert_contains "$ACTION_LOG" 'Invalid characters in claude_cli_version'; then
  test_pass "4.6 claude_cli_version: newline rejected with error"
else
  test_fail "4.6 claude_cli_version: newline rejected" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# ==============================================================================
# 5. Gradle secrets tests (TD-2442)
# ==============================================================================

read -r -d '' GOLDEN_POD_YAML <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-test-1-1-a1
  namespace: test-ns
  labels:
    app: kaniko-builder
spec:
  activeDeadlineSeconds: 7800
  initContainers:
  - name: merge-docker-config
    image: busybox:1.36
    command: ["sh", "-c"]
    args:
    - |
      cp /secret-orig/.dockerconfigjson /docker-config/config.json 2>/dev/null || echo '{"auths":{}}' > /docker-config/config.json
      tr -d '\r\n' < /docker-config/config.json > /docker-config/config.json.flat && mv /docker-config/config.json.flat /docker-config/config.json
      if [ -n "$REGISTRY_B64" ]; then
        sed -i -E "s|,[[:space:]]*\"$REGISTRY_SERVER\"[[:space:]]*:[[:space:]]*\{[^{}]*\}||g" /docker-config/config.json
        sed -i -E "s|\"$REGISTRY_SERVER\"[[:space:]]*:[[:space:]]*\{[^{}]*\}[[:space:]]*,?||g" /docker-config/config.json
        if grep -q -E '"auths"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}' /docker-config/config.json; then
          sed -i -E 's|"auths"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}|"auths":{"'"$REGISTRY_SERVER"'":{"auth":"'"$REGISTRY_B64"'"}}|' /docker-config/config.json
        elif grep -q -E '"auths"[[:space:]]*:[[:space:]]*\{' /docker-config/config.json; then
          sed -i -E 's|"auths"[[:space:]]*:[[:space:]]*\{|"auths":{"'"$REGISTRY_SERVER"'":{"auth":"'"$REGISTRY_B64"'"},|' /docker-config/config.json
        else
          echo '{"auths":{"'"$REGISTRY_SERVER"'":{"auth":"'"$REGISTRY_B64"'"}}}' > /docker-config/config.json
        fi
        if ! grep -q "$REGISTRY_SERVER" /docker-config/config.json; then
          echo "::error::Failed to inject registry auth for $REGISTRY_SERVER"
          exit 1
        fi
      fi
      if [ -n "$DOCKERHUB_B64" ]; then
        DH_SRV="https://index.docker.io/v1/"
        sed -i -E "s|,[[:space:]]*\"$DH_SRV\"[[:space:]]*:[[:space:]]*\{[^{}]*\}||g" /docker-config/config.json
        sed -i -E "s|\"$DH_SRV\"[[:space:]]*:[[:space:]]*\{[^{}]*\}[[:space:]]*,?||g" /docker-config/config.json
        if grep -q -E '"auths"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}' /docker-config/config.json; then
          sed -i -E 's|"auths"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}|"auths":{"https://index.docker.io/v1/":{"auth":"'"$DOCKERHUB_B64"'"}}|' /docker-config/config.json
        elif grep -q -E '"auths"[[:space:]]*:[[:space:]]*\{' /docker-config/config.json; then
          sed -i -E 's|"auths"[[:space:]]*:[[:space:]]*\{|"auths":{"https://index.docker.io/v1/":{"auth":"'"$DOCKERHUB_B64"'"},|' /docker-config/config.json
        else
          echo '{"auths":{"https://index.docker.io/v1/":{"auth":"'"$DOCKERHUB_B64"'"}}}' > /docker-config/config.json
        fi
        if ! grep -q "https://index.docker.io/v1/" /docker-config/config.json; then
          echo "::error::Failed to inject Docker Hub auth"
          exit 1
        fi
      fi
    env:
    - name: DOCKERHUB_B64
      value: ""
    - name: REGISTRY_B64
      value: ""
    - name: REGISTRY_SERVER
      value: "registry.thedevs.ru"
    volumeMounts:
    - name: secret-orig
      mountPath: /secret-orig
      readOnly: true
    - name: docker-config
      mountPath: /docker-config
    resources:
      requests:
        memory: "32Mi"
        cpu: "50m"
      limits:
        memory: "64Mi"
        cpu: "100m"
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.2
    args:
    - "--context=git://x-access-token:token123@github.com/test-org/test-repo.git#refs/heads/dev"
    - "--destination=registry.thedevs.ru/test-image:test-tag"
    - "--dockerfile=Dockerfile"
    - "--build-arg=CACHEBUST=1-1"
    - "--insecure"
    - "--insecure-pull"
    - "--cache=true"
    - "--cache-repo=registry.thedevs.ru/test-image/cache"
    - "--cache-ttl=168h"
    resources:
      requests:
        memory: "2Gi"
        cpu: "1000m"
      limits:
        memory: "8Gi"
        cpu: "16000m"
    volumeMounts:
    - name: docker-config
      mountPath: /kaniko/.docker
    - name: shared-cache
      mountPath: /root/.gradle/wrapper
      subPath: gradle-wrapper
    - name: shared-cache
      mountPath: /root/.vaadin
      subPath: vaadin-root-cache
    - name: shared-cache
      mountPath: /root/.gradle/nodejs
      subPath: gradle-nodejs
    - name: shared-cache
      mountPath: /root/.npm
      subPath: npm-cache
    - name: project-cache
      mountPath: /root/.gradle/caches
  restartPolicy: Never
  volumes:
  - name: secret-orig
    secret:
      secretName: test-secret
      optional: true
  - name: docker-config
    emptyDir: {}
  - name: shared-cache
    persistentVolumeClaim:
      claimName: kaniko-cache
  - name: project-cache
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# 5.1 Security: gradle credentials not leaked to YAML, logs, or argv
run_action INPUT_GRADLE_USERNAME="supersecretuser" INPUT_GRADLE_PASSWORD="supersecretpassword123"
captured_content=$(cat "$CAPTURED_YAML" 2>/dev/null || true)
argv_log=$(get_kubectl_argv)
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_not_contains "$captured_content" "supersecretuser" && \
   assert_not_contains "$captured_content" "supersecretpassword123" && \
   assert_not_contains "$ACTION_LOG" "supersecretuser" && \
   assert_not_contains "$ACTION_LOG" "supersecretpassword123" && \
   assert_not_contains "$argv_log" "supersecretuser" && \
   assert_not_contains "$argv_log" "supersecretpassword123" && \
   assert_not_contains "$calls" "apply secret"; then
  test_pass "5.1 Security: credentials not leaked to pod YAML, action logs, or kubectl argv"
else
  test_fail "5.1 Security: credentials leaked" "RC=$ACTION_RC, argv='$argv_log'"
fi

# 5.2 Properties format: verify properties file generated with correct keys and backslash escaping
run_action INPUT_GRADLE_USERNAME='corp\user' INPUT_GRADLE_PASSWORD='pass\word#123'
prop_content=$(cat "$TEST_DIR/saved_prop_file" 2>/dev/null || true)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$prop_content" "thedevsRepoUser=corp\\\\user" && \
   assert_contains "$prop_content" "thedevsRepoPassword=pass\\\\word#123" && \
   assert_contains "$prop_content" "uploadUser=corp\\\\user" && \
   assert_contains "$prop_content" "uploadPassword=pass\\\\word#123"; then
  test_pass "5.2 Properties format: correct keys and backslash escaping"
else
  test_fail "5.2 Properties format" "RC=$ACTION_RC, prop='$prop_content'"
fi

# 5.3 Ephemeral secret creation, direct volume mount, and ownerReferences
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword"
captured_content=$(cat "$CAPTURED_YAML" 2>/dev/null || true)
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$calls" "create secret generic kaniko-test-1-1-a1-gradle" && \
   assert_not_contains "$calls" "apply secret" && \
   assert_contains "$calls" "patch secret" && \
   assert_contains "$calls" "ownerReferences" && \
   assert_contains "$captured_content" "name: gradle-secret" && \
   assert_contains "$captured_content" "mountPath: /root/.gradle/gradle.properties" && \
   assert_contains "$captured_content" "subPath: gradle.properties" && \
   assert_contains "$captured_content" "readOnly: true" && \
   assert_contains "$captured_content" "secretName: kaniko-test-1-1-a1-gradle" && \
   assert_contains "$captured_content" "key: gradle.properties" && \
   assert_contains "$captured_content" "defaultMode: 0400"; then
  test_pass "5.3 Ephemeral secret: create, direct mount, defaultMode: 0400, subPath, ownerReferences"
else
  test_fail "5.3 Ephemeral secret mount" "RC=$ACTION_RC, yaml='$captured_content', calls='$calls'"
fi

# 5.4.1 Secret creation failure: RBAC Forbidden -> exit 1, error message, pod NOT created
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword" MOCK_SECRET_CREATE_FORBIDDEN="1"
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "::error::RBAC permission denied to create temporary gradle secret" && \
   assert_contains "$ACTION_LOG" "Ensure the service account from BUILDER_CONFIG_K8S has 'get', 'create', 'delete', and 'patch' verbs on 'secrets'" && \
   assert_not_contains "$calls" "apply pod" && \
   assert_not_contains "$calls" "apply secret"; then
  test_pass "5.4.1 Secret creation error: RBAC Forbidden -> fail-fast, diagnostic error, no pod created"
else
  test_fail "5.4.1 Secret creation error RBAC" "RC=$ACTION_RC, log='$ACTION_LOG', calls='$calls'"
fi

# 5.4.2 Secret creation failure: Transient failure -> retry with backoff, exit 1 after MAX_ATTEMPTS, eager cleanup
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword" MOCK_SECRET_CREATE_TRANSIENT="1"
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "Transient failure creating gradle secret — retrying in 10s" && \
   assert_contains "$ACTION_LOG" "Transient failure creating gradle secret — retrying in 30s" && \
   assert_contains "$ACTION_LOG" "::error::Failed to create temporary gradle secret" && \
   assert_not_contains "$calls" "apply pod" && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a1-gradle" && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a2-gradle" && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a3-gradle"; then
  test_pass "5.4.2 Secret creation error: Transient failure -> retries with backoff, eager cleanup registration, exit 1, no pod created"
else
  test_fail "5.4.2 Secret creation error transient" "RC=$ACTION_RC, log='$ACTION_LOG', calls='$calls'"
fi

# 5.4.3 Immediate delete secret invocation on failed create attempt
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword" MOCK_SECRET_CREATE_TRANSIENT="1"
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a1-gradle"; then
  test_pass "5.4.3 Immediate delete secret invocation on failed create attempt"
else
  test_fail "5.4.3 Immediate delete secret" "RC=$ACTION_RC, calls='$calls'"
fi

# 5.5.1 Cleanup: delete secret on pod apply failure
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword" MOCK_POD_APPLY_FAIL="1"
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a1-gradle" && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a2-gradle" && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a3-gradle"; then
  test_pass "5.5.1 Cleanup: pod apply failure triggers immediate delete secret for each attempt"
else
  test_fail "5.5.1 Cleanup on pod apply fail" "RC=$ACTION_RC, calls='$calls'"
fi

# 5.5.2 Cleanup: delete secrets on script exit via trap
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword"
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$calls" "delete secret kaniko-test-1-1-a1-gradle"; then
  test_pass "5.5.2 Cleanup: temporary secret deleted on script exit via trap"
else
  test_fail "5.5.2 Cleanup via trap" "RC=$ACTION_RC, calls='$calls'"
fi

# 5.6 Isolation: default run without gradle_* parameters produces byte-for-byte identical manifest matching golden baseline
run_action
actual_yaml=$(cat "$CAPTURED_YAML" 2>/dev/null || true)
calls=$(get_kubectl_calls)
diff_out=$(diff -u <(echo "$GOLDEN_POD_YAML") <(echo "$actual_yaml") || true)
if [ "$ACTION_RC" -eq 0 ] && \
   [ -z "$diff_out" ] && \
   assert_not_contains "$actual_yaml" "gradle-secret" && \
   assert_not_contains "$actual_yaml" "gradle.properties" && \
   assert_not_contains "$calls" "create secret" && \
   assert_not_contains "$calls" "delete secret"; then
  test_pass "5.6 Isolation: default run produces byte-for-byte identical YAML matching golden baseline without gradle secrets"
else
  test_fail "5.6 Isolation" "RC=$ACTION_RC, diff: $diff_out"
fi

# 5.7.1 Validation: only username without password -> error
run_action INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD=""
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "::error::Both gradle_username and gradle_password must be specified together."; then
  test_pass "5.7.1 Validation: only username without password rejected"
else
  test_fail "5.7.1 Validation: only username" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 5.7.2 Validation: only password without username -> error
run_action INPUT_GRADLE_USERNAME="" INPUT_GRADLE_PASSWORD="testpassword"
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "::error::Both gradle_username and gradle_password must be specified together."; then
  test_pass "5.7.2 Validation: only password without username rejected"
else
  test_fail "5.7.2 Validation: only password" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 5.7.3 Validation: LF in username -> error
run_action INPUT_GRADLE_USERNAME=$'user\nname' INPUT_GRADLE_PASSWORD="testpassword"
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "::error::gradle_username and gradle_password must not contain CR or LF characters."; then
  test_pass "5.7.3 Validation: newline in username rejected"
else
  test_fail "5.7.3 Validation: newline in username" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 5.7.4 Validation: CR in password -> error
run_action INPUT_GRADLE_USERNAME="user" INPUT_GRADLE_PASSWORD=$'pass\rword'
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "::error::gradle_username and gradle_password must not contain CR or LF characters."; then
  test_pass "5.7.4 Validation: CR in password rejected"
else
  test_fail "5.7.4 Validation: CR in password" "RC=$ACTION_RC, log='$ACTION_LOG'"
fi

# 5.7.5 Validation: leading whitespace in username or password -> error
run_action INPUT_GRADLE_USERNAME=" user" INPUT_GRADLE_PASSWORD="password"
res1_rc=$ACTION_RC
res1_log=$ACTION_LOG
run_action INPUT_GRADLE_USERNAME="user" INPUT_GRADLE_PASSWORD=" password"
res2_rc=$ACTION_RC
res2_log=$ACTION_LOG
if [ "$res1_rc" -ne 0 ] && assert_contains "$res1_log" "::error::gradle_username and gradle_password must not contain leading whitespace." && \
   [ "$res2_rc" -ne 0 ] && assert_contains "$res2_log" "::error::gradle_username and gradle_password must not contain leading whitespace."; then
  test_pass "5.7.5 Validation: leading whitespace in username or password rejected"
else
  test_fail "5.7.5 Validation: leading whitespace" "RC1=$res1_rc, RC2=$res2_rc"
fi

# 5.7.6 Validation: non-printable or non-ASCII characters in username or password -> error
run_action INPUT_GRADLE_USERNAME="юзер" INPUT_GRADLE_PASSWORD="password"
res1_rc=$ACTION_RC
res1_log=$ACTION_LOG
run_action INPUT_GRADLE_USERNAME="user" INPUT_GRADLE_PASSWORD="пароль"
res2_rc=$ACTION_RC
res2_log=$ACTION_LOG
if [ "$res1_rc" -ne 0 ] && assert_contains "$res1_log" "::error::gradle_username and gradle_password must contain only printable ASCII characters." && \
   [ "$res2_rc" -ne 0 ] && assert_contains "$res2_log" "::error::gradle_username and gradle_password must contain only printable ASCII characters."; then
  test_pass "5.7.6 Validation: non-ASCII characters in username or password rejected"
else
  test_fail "5.7.6 Validation: non-ASCII characters" "RC1=$res1_rc, RC2=$res2_rc"
fi

# 5.8.1 Fail-Fast: missing gradle_secret -> exit 1, error message, no pod created
run_action INPUT_GRADLE_SECRET="missing-secret" MOCK_GET_SECRET_NOT_FOUND="missing-secret"
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -ne 0 ] && \
   assert_contains "$ACTION_LOG" "::error::Gradle secret 'missing-secret' specified but not found in namespace 'test-ns'" && \
   assert_not_contains "$calls" "apply pod"; then
  test_pass "5.8.1 Fail-Fast: missing gradle_secret results in exit 1 without creating pod"
else
  test_fail "5.8.1 Fail-Fast: missing gradle_secret" "RC=$ACTION_RC, log='$ACTION_LOG', calls='$calls'"
fi

# 5.8.2 Existing gradle_secret mounted successfully
run_action INPUT_GRADLE_SECRET="my-custom-secret"
captured_content=$(cat "$CAPTURED_YAML" 2>/dev/null || true)
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$captured_content" "name: gradle-secret" && \
   assert_contains "$captured_content" "secretName: my-custom-secret" && \
   assert_contains "$captured_content" "mountPath: /root/.gradle/gradle.properties" && \
   assert_contains "$captured_content" "subPath: gradle.properties" && \
   assert_not_contains "$calls" "create secret"; then
  test_pass "5.8.2 Pre-existing gradle_secret mounted directly without temporary secret creation"
else
  test_fail "5.8.2 Pre-existing gradle_secret mount" "RC=$ACTION_RC, yaml='$captured_content'"
fi

# 5.8.3 Precedence: credentials take precedence over gradle_secret with warning
run_action INPUT_GRADLE_SECRET="pre-existing-secret" INPUT_GRADLE_USERNAME="testuser" INPUT_GRADLE_PASSWORD="testpassword"
captured_content=$(cat "$CAPTURED_YAML" 2>/dev/null || true)
calls=$(get_kubectl_calls)
if [ "$ACTION_RC" -eq 0 ] && \
   assert_contains "$ACTION_LOG" "::warning::Both gradle credentials (gradle_username/gradle_password) and gradle_secret provided. Ephemeral secret from credentials takes precedence; gradle_secret 'pre-existing-secret' is ignored." && \
   assert_contains "$captured_content" "secretName: kaniko-test-1-1-a1-gradle" && \
   assert_not_contains "$captured_content" "pre-existing-secret" && \
   assert_contains "$calls" "create secret generic kaniko-test-1-1-a1-gradle"; then
  test_pass "5.8.3 Precedence: credentials take precedence over gradle_secret with warning"
else
  test_fail "5.8.3 Precedence" "RC=$ACTION_RC, log='$ACTION_LOG', yaml='$captured_content'"
fi

# ==============================================================================
# Test Summary
# ==============================================================================
echo ""
echo "=== Test Results: $PASSED / $TOTAL passed ($FAILED failed) ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
