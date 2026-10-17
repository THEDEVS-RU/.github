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
    echo "Succeeded"
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
  rm -f "$CAPTURED_YAML" "$output_file"
  local rc=0
  (
    export PATH="$BIN_DIR:$PATH"
    export KUBECTL_CAPTURED_YAML="$CAPTURED_YAML"
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
# Test Summary
# ==============================================================================
echo ""
echo "=== Test Results: $PASSED / $TOTAL passed ($FAILED failed) ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
