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
include 'sample-lib'
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

cat > "$UPSTREAM_DIR/itink-mod/src/main/java/ru/thedevs/itink/ItinkAutoConfiguration.java" <<'EOF'
package ru.thedevs.itink;
public class ItinkAutoConfiguration {
}
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/main/resources/META-INF/spring"
cat > "$UPSTREAM_DIR/itink-mod/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" <<'EOF'
ru.thedevs.itink.ItinkAutoConfiguration
EOF

mkdir -p "$UPSTREAM_DIR/itink-mod/src/test/java/ru/thedevs/itink"
cat > "$UPSTREAM_DIR/itink-mod/src/test/java/ru/thedevs/itink/ItinkTest.java" <<'EOF'
package ru.thedevs.itink;

import org.junit.jupiter.api.Test;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

public class ItinkTest {
    @Test
    void testItinkService() throws Exception {
        assertEquals("hello from itink", new ItinkService().message());
        String changelog = System.getProperty("main.liquibase.change-log");
        assertNotNull(changelog, "main.liquibase.change-log must be set");
        assertTrue(changelog.startsWith("classpath:") || changelog.startsWith("file:"), "changelog must have classpath: or file: prefix");
        if (changelog.startsWith("classpath:")) {
            String res = changelog.substring("classpath:".length());
            while (res.startsWith("/")) res = res.substring(1);
            assertNotNull(getClass().getClassLoader().getResource(res), "Changelog resource must be resolvable via ClassLoader: " + res);
        }
        assertNotNull(getClass().getClassLoader().getResource("ru/thedevs/consumer/liquibase/changelog.xml"),
                "Host changelog must be resolvable via ClassLoader from host-resources");

        // (a) Verify host autoconfiguration imports descriptors are excluded, while dependency descriptor is present
        Enumeration<URL> importsUrls = getClass().getClassLoader().getResources(
                "META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports");
        List<String> importsEntries = new ArrayList<>();
        while (importsUrls.hasMoreElements()) {
            URL url = importsUrls.nextElement();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(url.openStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    line = line.trim();
                    if (!line.isEmpty() && !line.startsWith("#")) {
                        importsEntries.add(line);
                    }
                }
            }
        }
        assertTrue(importsEntries.contains("ru.thedevs.itink.ItinkAutoConfiguration"),
                "Dependency autoconfiguration must be present on classpath: " + importsEntries);
        assertFalse(importsEntries.contains("ru.thedevs.consumer.ConsumerMainAutoConfiguration"),
                "Host main autoconfiguration descriptor must be excluded from classpath: " + importsEntries);
        assertFalse(importsEntries.contains("ru.thedevs.consumer.starter.ConsumerAutoConfiguration"),
                "Host starter autoconfiguration descriptor must be excluded from classpath: " + importsEntries);

        // (б) Verify host classes are preserved and loadable from classpath
        assertNotNull(Class.forName("ru.thedevs.consumer.starter.ConsumerAutoConfiguration"),
                "Host starter class must be loadable");
        assertNotNull(Class.forName("ru.thedevs.consumer.ConsumerService"),
                "Host main class must be loadable");

        // (в) Verify dependency test system properties are preserved without being overwritten by harness
        assertEquals("ru.thedevs.itink.CustomExcludedAutoConfiguration",
                System.getProperty("spring.autoconfigure.exclude"),
                "Dependency spring.autoconfigure.exclude system property must be preserved");
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
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
    testImplementation(dependencies.create(project(':helper-test')) {
        exclude group: 'org.slf4j', module: 'slf4j-api'
    })
}
test {
    systemProperty 'spring.autoconfigure.exclude', 'ru.thedevs.itink.CustomExcludedAutoConfiguration'
}
publishing {
    publications {
        javaMaven(MavenPublication) {
            artifactId = base.archivesName.get()
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

# sample-lib: library published without tests (used to test strict vs pre-rollout)
mkdir -p "$UPSTREAM_DIR/sample-lib/src/main/java/ru/thedevs/sample"
cat > "$UPSTREAM_DIR/sample-lib/src/main/java/ru/thedevs/sample/Sample.java" <<'EOF'
package ru.thedevs.sample;
public class Sample {
    public static String get() { return "sample"; }
}
EOF

cat > "$UPSTREAM_DIR/sample-lib/build.gradle" <<EOF
plugins {
    id 'java'
    id 'maven-publish'
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
  # Publish itink-mod, upstream-starter, helper-test via ci-addon-tests.init.gradle
  gradle -I "$INIT_SCRIPT" :itink-mod:publishAllPublicationsToLocalRepoRepository :upstream-starter:publishAllPublicationsToLocalRepoRepository :helper-test:publishAllPublicationsToLocalRepoRepository --no-daemon
  # Publish sample-lib WITHOUT init script so it has NO -tests artifact published
  gradle :sample-lib:publishAllPublicationsToLocalRepoRepository --no-daemon
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

if ! echo "$TEST_PROPS" | grep -q "thedevs.test.systemProperties.spring.autoconfigure.exclude=ru.thedevs.itink.CustomExcludedAutoConfiguration"; then
  echo "FAIL: thedevs.test.systemProperties.spring.autoconfigure.exclude not found or incorrect in $TEST_PROPS_FILE" >&2
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

cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/java/ru/thedevs/consumer/ConsumerMainAutoConfiguration.java" <<'EOF'
package ru.thedevs.consumer;
public class ConsumerMainAutoConfiguration {
}
EOF

mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/META-INF/spring"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" <<'EOF'
ru.thedevs.consumer.ConsumerMainAutoConfiguration
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

# Host changelog in main resources (not test resources!)
mkdir -p "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/ru/thedevs/consumer/liquibase"
cat > "$DOWNSTREAM_DIR/consumer-mod/src/main/resources/ru/thedevs/consumer/liquibase/changelog.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">
</databaseChangeLog>
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
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
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

mkdir -p "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/META-INF/spring"
cat > "$DOWNSTREAM_DIR/consumer-starter/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" <<'EOF'
ru.thedevs.consumer.starter.ConsumerAutoConfiguration
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

# Verify host resources were filtered into isolated directories without autoconfiguration imports
HOST_MAIN_CHANGELOG="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/main/ru/thedevs/consumer/liquibase/changelog.xml"
if [ ! -f "$HOST_MAIN_CHANGELOG" ]; then
  echo "FAIL: Host main changelog not found in host-resources/main at $HOST_MAIN_CHANGELOG" >&2
  exit 1
fi

if [ -f "$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/main/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" ]; then
  echo "FAIL: Host main autoconfiguration descriptor found in host-resources/main, but must be excluded!" >&2
  exit 1
fi

if [ -f "$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/host-resources/starter/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports" ]; then
  echo "FAIL: Host starter autoconfiguration descriptor found in host-resources/starter, but must be excluded!" >&2
  exit 1
fi

# Verify unpacked classes
UNPACKED_TEST_CLASS="$DOWNSTREAM_DIR/consumer-mod/build/addon-tests/itink/classes/ru/thedevs/itink/ItinkTest.class"
if [ ! -f "$UNPACKED_TEST_CLASS" ]; then
  echo "FAIL: Unpacked dependency test class not found at $UNPACKED_TEST_CLASS" >&2
  exit 1
fi

# Verify test report confirms actual execution (tests="1", failures="0", errors="0")
REPORT_FILE="$DOWNSTREAM_DIR/consumer-mod/build/test-results/testAddon_itink/TEST-ru.thedevs.itink.ItinkTest.xml"
if [ ! -f "$REPORT_FILE" ]; then
  echo "FAIL: Test report file not found at $REPORT_FILE" >&2
  exit 1
fi

if ! grep -q 'tests="1"' "$REPORT_FILE" || ! grep -q 'failures="0"' "$REPORT_FILE" || ! grep -q 'errors="0"' "$REPORT_FILE"; then
  echo "FAIL: Test report does not indicate exactly 1 passing test without failures or errors" >&2
  cat "$REPORT_FILE" >&2
  exit 1
fi

echo "Downstream testAddon execution validation: PASSED"

# 5. Validate Strict Mode vs Pre-rollout for missing tests artifact
# We verify in the SAME directory that switching to strict mode invalidates UP-TO-DATE and fails.
echo "Testing strict mode vs pre-rollout mode behavior in same consumer directory..."

STRICT_TEST_DIR="$TEST_DIR/strict-consumer"
mkdir -p "$STRICT_TEST_DIR"
cat > "$STRICT_TEST_DIR/settings.gradle" <<'EOF'
rootProject.name = 'strict-consumer'
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
    implementation 'ru.thedevs:sample-lib:1.0.0'
}
EOF

# In pre-rollout mode (default), missing tests artifact prints warning and succeeds
set +e
PRE_ROLLOUT_OUTPUT=$(cd "$STRICT_TEST_DIR" && gradle -I "$INIT_SCRIPT" testAddonDependencies --no-daemon 2>&1)
PRE_RC=$?
set -e

if [ "$PRE_RC" -ne 0 ]; then
  echo "FAIL: Build failed in pre-rollout mode with exit code $PRE_RC (expected success with warning)" >&2
  echo "$PRE_ROLLOUT_OUTPUT" >&2
  exit 1
fi

if ! echo "$PRE_ROLLOUT_OUTPUT" | grep -q "Skipped dependency tests for 'ru.thedevs:sample-lib'"; then
  echo "FAIL: Pre-rollout warning not printed for missing tests artifact" >&2
  echo "$PRE_ROLLOUT_OUTPUT" >&2
  exit 1
fi

# In strict mode (-Pthedevs.tests.strict=true), missing tests artifact must fail in the SAME directory
set +e
STRICT_OUTPUT=$(cd "$STRICT_TEST_DIR" && gradle -I "$INIT_SCRIPT" testAddonDependencies -Pthedevs.tests.strict=true --no-daemon 2>&1)
STRICT_RC=$?
set -e

if [ "$STRICT_RC" -eq 0 ]; then
  echo "FAIL: Build succeeded in strict mode with missing tests artifact in same directory, but must fail!" >&2
  echo "$STRICT_OUTPUT" >&2
  exit 1
fi

if ! echo "$STRICT_OUTPUT" | grep -q "Strict mode enabled"; then
  echo "FAIL: Expected strict mode failure message, got:" >&2
  echo "$STRICT_OUTPUT" >&2
  exit 1
fi

echo "Strict mode vs pre-rollout behavior in same directory: PASSED"

echo "=== All Contract Tests for setup-addon-tests PASSED ==="
