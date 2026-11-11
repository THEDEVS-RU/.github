#!/usr/bin/env bash
# Targeted hook smoke only, independent of the full TD-2039 fixture suite.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/src/test/java/sample"
cat > "$FIXTURE/settings.gradle" <<'GRADLE'
rootProject.name = 'observation-fixture'
GRADLE
cat > "$FIXTURE/build.gradle" <<'GRADLE'
plugins { id 'java' }
repositories { mavenCentral() }
dependencies {
    testImplementation 'org.junit.jupiter:junit-jupiter-api:5.10.2'
    testRuntimeOnly 'org.junit.jupiter:junit-jupiter-engine:5.10.2'
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher:1.10.2'
}
tasks.withType(Test).configureEach { useJUnitPlatform() }
tasks.register('headlessTest', Test) {
    testClassesDirs = sourceSets.test.output.classesDirs
    classpath = sourceSets.test.runtimeClasspath
}
tasks.register('emptyTest', Test) { testClassesDirs = files() }
GRADLE
cat > "$FIXTURE/src/test/java/sample/ObservedTest.java" <<'JAVA'
package sample;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.DynamicTest;
import java.util.stream.Stream;
public class ObservedTest {
    @TestFactory Stream<DynamicTest> dynamic() {
        return Stream.of(DynamicTest.dynamicTest("case[1]", () -> {}), DynamicTest.dynamicTest("case[2]", () -> {}));
    }
    @Nested class Inner {
        @Disabled @Test void skipped() {}
        @Test void executes() {}
    }
}
JAVA
THEDEVS_TEST_LANE=own "${GRADLE_COMMAND:-gradle}" -p "$FIXTURE" -I "$SCRIPT_DIR/../actions/setup-addon-tests/test-observability.init.gradle" test --tests sample.ObservedTest headlessTest --tests sample.ObservedTest emptyTest --profile --no-daemon
python3 - "$FIXTURE" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root/'build/addon-test-observability/own/manifest.json').read_text())
assert manifest['schemaVersion'] == 1 and manifest['phase'] == 'complete'
tasks = {task['path']: task for task in manifest['tasks']}
assert set(tasks) == {':test', ':headlessTest', ':emptyTest'}, tasks
for path in (':test', ':headlessTest'):
    task = tasks[path]
    assert task['state'] == 'success', task
    assert task['counts'] == {'tests': 4, 'passed': 3, 'failed': 0, 'skipped': 1}, task
    assert task['elapsedNanos'] > 0 and task['startedAt'] and task['endedAt']
assert tasks[':emptyTest']['state'] == 'no-source', tasks
suites = [json.loads(line) for line in (root/'build/addon-test-observability/own/suites.jsonl').read_text().splitlines()]
assert len([row for row in suites if row['parent'] is None]) == 2
assert all(row['timing'] == 'overlaps-task-wall' for row in suites)
PY
