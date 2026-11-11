#!/usr/bin/env bash
# Targeted hook smoke only, independent of the full TD-2039 fixture suite.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE=$(mktemp -d)
REPORT_TEMP=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$REPORT_TEMP"' EXIT
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
// This smoke must execute hooks even when a developer has a global Gradle cache.
tasks.withType(Test).configureEach { outputs.cacheIf { false } }
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

# Exercise the production collector against actual Gradle-generated XML, full HTML
# assets, profile and observation metadata, rather than hand-written report shapes.
GITHUB_WORKSPACE="$FIXTURE" RUNNER_TEMP="$REPORT_TEMP" \
GITHUB_OUTPUT="$REPORT_TEMP/outputs" GITHUB_STEP_SUMMARY="$REPORT_TEMP/summary" \
GITHUB_REPOSITORY=fixture/observation GITHUB_JOB=test-own \
REPORT_LANE=own REPORT_MANIFEST=build/addon-test-observability/own/manifest.json \
REPORT_TEST_OUTCOME=success REPORT_RUN_ID=123 REPORT_RUN_ATTEMPT=1 \
REPORT_HEAD_SHA=1111111111111111111111111111111111111111 \
REPORT_ACTION_SHA=2222222222222222222222222222222222222222 \
REPORT_SECRET_USER=fixture-private-user REPORT_SECRET_PASSWORD=fixture-private-password \
REPORT_ROOTS=$'build/test-results\nbuild/reports/tests\nbuild/reports/profile\nbuild/addon-test-observability/own' \
python3 "$SCRIPT_DIR/../actions/collect-addon-test-reports/collect-reports.py"
python3 - "$FIXTURE" "$REPORT_TEMP" <<'PY_REPORTS'
import hashlib, json, pathlib, sys
fixture, temporary = map(pathlib.Path, sys.argv[1:])
outputs = dict(line.split('=', 1) for line in (temporary/'outputs').read_text().splitlines())
assert outputs['ready'] == 'true' and outputs['complete'] == 'true', outputs
staging = pathlib.Path(outputs['artifact-path'])
assert staging.is_relative_to(temporary) and not staging.is_relative_to(fixture), staging
status = json.loads((staging/'collection-status.json').read_text())
assert status['complete'] and status['counts'] == {'passed': 6, 'failed': 0, 'skipped': 2}, status
assert {task['path'] for task in status['tasks']} == {':test', ':headlessTest', ':emptyTest'}
assert not list(staging.glob('build/test-results/**/binary/*')), 'Gradle binary outputs must never be uploaded'
for root in ('build/test-results', 'build/reports/tests', 'build/reports/profile', 'build/addon-test-observability/own'):
    for source in (fixture/root).rglob('*'):
        if not source.is_file() or 'binary' in source.relative_to(fixture).parts:
            continue
        copied = staging/source.relative_to(fixture)
        assert copied.is_file(), copied
        assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256(copied.read_bytes()).digest(), copied
summary = (temporary/'summary').read_text()
assert 'Cases passed/failed/skipped: 6/0/2' in summary, summary
assert 'Reports: complete' in summary, summary
assert len(summary.encode()) <= 16384 and len(summary.splitlines()) <= 80
print('Actual Gradle reports collected safely: raw XML/full HTML/profile preserved; binary files excluded')
PY_REPORTS
