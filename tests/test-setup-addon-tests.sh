#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../actions/setup-addon-tests/ci-addon-tests.init.gradle"

if [ ! -f "$INIT_SCRIPT" ]; then
  echo "Error: init script not found at $INIT_SCRIPT" >&2
  exit 1
fi

echo "=== TD-2039: Contract Tests for setup-addon-tests ==="

TEST_DIR=$(mktemp -d -t td2039-tests-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

REPO_DIR="$TEST_DIR/local-repo"
mkdir -p "$REPO_DIR"

UPSTREAM_DIR="$TEST_DIR/upstream"
mkdir -p "$UPSTREAM_DIR"

# 1. Upstream Fixture Setup
# Fixture includes a module with archivesName != moduleName (like addon-tinkoff: base.archivesName = 'itink')
cat > "$UPSTREAM_DIR/settings.gradle" <<'EOF'
rootProject.name = 'addon-upstream'
include 'itink-mod'
include 'upstream-starter'
include 'helper-test'
EOF

cat > "$UPSTREAM_DIR/build.gradle" <<'EOF'
allprojects {
    group = 'ru.thedevs'
    version = '1.0.0'
    repositories {
        mavenCentral()
    }
}
EOF

# itink-mod: archivesName is 'itink'
mkdir -p "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink"
cat > "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink/ItinkService.java" <<'EOF'
package ru.thedevs.itink;
public class ItinkService {
    public String message() { return "hello from itink"; }
}
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/test/java/ru/thedevs/itink"
cat > "$UPSTREAM_DIR/itink-mod/src/test/java/ru/thedevs/itink/ItinkTest.java" <<'EOF'
package ru.thedevs.itink;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

public class ItinkTest {
    @Test
    void testItinkService() {
        assertEquals("hello from itink", new ItinkService().message());
    }
}
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/test/resources"
cat > "$UPSTREAM_DIR/itink-mod/src/test/resources/test-itink.properties" <<'EOF'
main.liquibase.change-log=ru/thedevs/itink/liquibase/changelog.xml
EOF

cat > "$UPSTREAM_DIR/itink-mod/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
}
base {
    archivesName = 'itink'
}
dependencies {
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
    testImplementation project(':helper-test') {
        exclude group: 'org.slf4j', module: 'slf4j-api'
    }
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# upstream-starter
mkdir -p "$UPSTREAM_DIR/upstream-starter/src/main/java/ru/thedevs/starter"
cat > "$UPSTREAM_DIR/upstream-starter/src/main/java/ru/thedevs/starter/UpstreamAutoConfiguration.java" <<'EOF'
package ru.thedevs.starter;
public class UpstreamAutoConfiguration {
    public static final String ACTIVE = "true";
}
EOF

cat > "$UPSTREAM_DIR/upstream-starter/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
}
dependencies {
    implementation project(':itink-mod')
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

# helper-test
mkdir -p "$UPSTREAM_DIR/helper-test/src/main/java/ru/thedevs/helper"
cat > "$UPSTREAM_DIR/helper-test/src/main/java/ru/thedevs/helper/Helper.java" <<'EOF'
package ru.thedevs.helper;
public class Helper {
    public static String get() { return "helper"; }
}
EOF

cat > "$UPSTREAM_DIR/helper-test/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
}
dependencies {
    implementation 'org.slf4j:slf4j-api:2.0.16'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
    repositories {
        maven {
            name = 'localRepo'
            url = uri("${REPO_DIR}")
        }
    }
}
EOF

echo "Building and publishing upstream fixtures via ci-addon-tests.init.gradle..."
(
  cd "$UPSTREAM_DIR"
  gradle -I "$INIT_SCRIPT" publishAllPublicationsToLocalRepoRepository --no-daemon
)

# 2. Validate Published Artifacts and POM
echo "Validating published upstream artifacts..."
ITINK_TESTS_DIR="$REPO_DIR/ru/thedevs/itink-tests/1.0.0"
if [ ! -d "$ITINK_TESTS_DIR" ]; then
  echo "FAIL: itink-tests directory not found at $ITINK_TESTS_DIR" >&2
  exit 1
fi

if [ ! -f "$ITINK_TESTS_DIR/itink-tests-1.0.0.jar" ]; then
  echo "FAIL: itink-tests-1.0.0.jar not found at $ITINK_TESTS_DIR" >&2
  exit 1
fi

if [ ! -f "$ITINK_TESTS_DIR/itink-tests-1.0.0.pom" ]; then
  echo "FAIL: itink-tests-1.0.0.pom not found at $ITINK_TESTS_DIR" >&2
  exit 1
fi

# GMM must be disabled
if [ -f "$ITINK_TESTS_DIR/itink-tests-1.0.0.module" ]; then
  echo "FAIL: GMM module metadata file found at $ITINK_TESTS_DIR/itink-tests-1.0.0.module, but GMM must be disabled!" >&2
  exit 1
fi

POM_CONTENT=$(cat "$ITINK_TESTS_DIR/itink-tests-1.0.0.pom")

# Must contain dependency on main module itink with compile scope
if ! echo "$POM_CONTENT" | grep -q "<artifactId>itink</artifactId>"; then
  echo "FAIL: POM missing main module dependency <artifactId>itink</artifactId>" >&2
  exit 1
fi

if ! echo "$POM_CONTENT" | grep -A 4 "<artifactId>itink</artifactId>" | grep -q "<scope>compile</scope>"; then
  echo "FAIL: POM main module dependency missing <scope>compile</scope>" >&2
  exit 1
fi

# Must contain dependency on helper-test with runtime scope
if ! echo "$POM_CONTENT" | grep -q "<artifactId>helper-test</artifactId>"; then
  echo "FAIL: POM missing test project dependency <artifactId>helper-test</artifactId>" >&2
  exit 1
fi

# Must preserve declared exclusions (org.slf4j / slf4j-api)
if ! echo "$POM_CONTENT" | grep -q "<groupId>org.slf4j</groupId>"; then
  echo "FAIL: POM missing exclusion for org.slf4j under helper-test" >&2
  exit 1
fi

if ! echo "$POM_CONTENT" | grep -q "<artifactId>slf4j-api</artifactId>"; then
  echo "FAIL: POM missing exclusion for slf4j-api under helper-test" >&2
  exit 1
fi

# Validate META-INF/thedevs-test.properties inside itink-tests-1.0.0.jar
unzip -q -o "$ITINK_TESTS_DIR/itink-tests-1.0.0.jar" -d "$TEST_DIR/unpacked-itink-tests"
TEST_PROPS_FILE="$TEST_DIR/unpacked-itink-tests/META-INF/thedevs-test.properties"
if [ ! -f "$TEST_PROPS_FILE" ]; then
  echo "FAIL: META-INF/thedevs-test.properties not found inside itink-tests-1.0.0.jar" >&2
  exit 1
fi

TEST_PROPS=$(cat "$TEST_PROPS_FILE")
if ! echo "$TEST_PROPS" | grep -q "thedevs.tests.disabled=false"; then
  echo "FAIL: thedevs.tests.disabled=false not found in $TEST_PROPS_FILE" >&2
  exit 1
fi

if ! echo "$TEST_PROPS" | grep -q "thedevs.test.liquibase.change-log=ru/thedevs/itink/liquibase/changelog.xml"; then
  echo "FAIL: thedevs.test.liquibase.change-log not found or incorrect in $TEST_PROPS_FILE" >&2
  exit 1
fi

echo "Published upstream artifacts and POM validation: PASSED"

# 3. Downstream Fixture Setup
# Downstream depends on upstream-starter.
# Starter mapping should map upstream-starter -> itink.
# afterEvaluate configuration mutation (emulating io.jmix) should not break resolution.
DOWNSTREAM_DIR="$TEST_DIR/downstream"
mkdir -p "$DOWNSTREAM_DIR"

cat > "$DOWNSTREAM_DIR/settings.gradle" <<'EOF'
rootProject.name = 'addon-downstream'
include 'consumer-mod'
include 'consumer-starter'
EOF

cat > "$DOWNSTREAM_DIR/build.gradle" <<EOF
allprojects {
    group = 'ru.thedevs'
    version = '1.0.0'
    repositories {
        maven { url = uri("${REPO_DIR}") }
        mavenCentral()
    }
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer/ConsumerService.java" <<'EOF'
package ru.thedevs.consumer;
public class ConsumerService {
    public String status() { return "consumer-ok"; }
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/test/java/ru/thedevs/consumer"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/test/java/ru/thedevs/consumer/ConsumerTest.java" <<'EOF'
package ru.thedevs.consumer;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertTrue;

public class ConsumerTest {
    @Test
    void testConsumer() {
        assertTrue(true);
    }
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/test/resources"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/test/resources/test-consumer.properties" <<'EOF'
main.liquibase.change-log=ru/thedevs/consumer/liquibase/changelog.xml
EOF

cat > "$DOWNSTREAM_DIR/consumer-mod/build.gradle" <<'EOF'
plugins {
    id 'java'
    id 'maven-publish'
}
dependencies {
    implementation 'ru.thedevs:upstream-starter:1.0.0'
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
}
// Emulate Jmix plugin mutating configurations in afterEvaluate
project.afterEvaluate {
    project.dependencies.add('implementation', 'org.slf4j:slf4j-api:2.0.16')
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            from components.java
        }
    }
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-starter/src/main/java/ru/thedevs/consumer/starter"
cat > "$DOWNSTREAM_DIR/consumer-starter/src/main/java/ru/thedevs/consumer/starter/ConsumerAutoConfiguration.java" <<'EOF'
package ru.thedevs.consumer.starter;
public class ConsumerAutoConfiguration {
    public static final String ACTIVE = "true";
}
EOF

cat > "$DOWNSTREAM_DIR/consumer-starter/build.gradle" <<'EOF'
plugins {
    id 'java'
}
dependencies {
    implementation project(':consumer-mod')
}
EOF

echo "Running downstream build and testAddonDependencies with ci-addon-tests.init.gradle..."
(
  cd "$DOWNSTREAM_DIR"
  gradle -I "$INIT_SCRIPT" :consumer-mod:testAddonDependencies --no-daemon
)

# 4. Validate Downstream Execution Results
echo "Validating downstream testAddon execution results..."

AGGREGATE_CHANGELOG="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/aggregate-changelog.xml"
if [ ! -f "$AGGREGATE_CHANGELOG" ]; then
  echo "FAIL: Aggregate changelog was not created at $AGGREGATE_CHANGELOG" >&2
  exit 1
fi

CHANGELOG_CONTENT=$(cat "$AGGREGATE_CHANGELOG")
if ! echo "$CHANGELOG_CONTENT" | grep -q "ru/thedevs/itink/liquibase/changelog.xml"; then
  echo "FAIL: Aggregate changelog missing dependency changelog" >&2
  exit 1
fi

if ! echo "$CHANGELOG_CONTENT" | grep -q "ru/thedevs/consumer/liquibase/changelog.xml"; then
  echo "FAIL: Aggregate changelog missing host changelog" >&2
  exit 1
fi

# Verify unpacked classes
UNPACKED_TEST_CLASS="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/classes/ru/thedevs/itink/ItinkTest.class"
if [ ! -f "$UNPACKED_TEST_CLASS" ]; then
  echo "FAIL: Unpacked dependency test class not found at $UNPACKED_TEST_CLASS" >&2
  exit 1
fi

# Verify test results generated in isolated folder
TEST_RESULTS_DIR="$DOWNSTREAM_DIR/consumer-mod/build/test-results/testAddon_itink"
if [ ! -d "$TEST_RESULTS_DIR" ]; then
  echo "FAIL: Isolated test results directory not found at $TEST_RESULTS_DIR" >&2
  exit 1
fi

echo "Downstream testAddon execution validation: PASSED"

# 5. Validate Strict Mode vs Pre-rollout for missing tests artifact
echo "Testing strict mode vs pre-rollout mode behavior..."

STRICT_TEST_DIR="$TEST_DIR/strict-test"
mkdir -p "$STRICT_TEST_DIR"
cat > "$STRICT_TEST_DIR/settings.gradle" <<'EOF'
rootProject.name = 'strict-test'
EOF
cat > "$STRICT_TEST_DIR/build.gradle" <<EOF
plugins {
    id 'java'
}
repositories {
    maven { url = uri("${REPO_DIR}") }
    mavenCentral()
}
dependencies {
    implementation 'ru.thedevs:helper-test:1.0.0'
}
EOF

# In pre-rollout mode (default), missing tests artifact prints warning and succeeds
PRE_ROLLOUT_OUTPUT=$(cd "$STRICT_TEST_DIR" && gradle -I "$INIT_SCRIPT" testAddonDependencies --no-daemon 2>&1)
if ! echo "$PRE_ROLLOUT_OUTPUT" | grep -q "Skipped dependency tests for 'ru.thedevs:helper-test'"; then
  echo "FAIL: Pre-rollout warning not printed for missing tests artifact" >&2
  echo "$PRE_ROLLOUT_OUTPUT" >&2
  exit 1
fi

# In strict mode (-Pthedevs.tests.strict=true), missing tests artifact must fail
set +e
STRICT_OUTPUT=$(cd "$STRICT_TEST_DIR" && gradle -I "$INIT_SCRIPT" testAddonDependencies -Pthedevs.tests.strict=true --no-daemon 2>&1)
STRICT_RC=$?
set -e

if [ "$STRICT_RC" -eq 0 ]; then
  echo "FAIL: Build succeeded in strict mode with missing tests artifact, but must fail!" >&2
  exit 1
fi

if ! echo "$STRICT_OUTPUT" | grep -q "Strict mode enabled"; then
  echo "FAIL: Expected strict mode failure message, got:" >&2
  echo "$STRICT_OUTPUT" >&2
  exit 1
fi

echo "Strict mode vs pre-rollout behavior: PASSED"

echo "=== All Contract Tests for setup-addon-tests PASSED ==="
