#!/usr/bin/env python3
"""Verify the opt-in journal against the original TD-2039 execution and local artifacts."""
import collections
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


def inventory(root):
    cases = collections.Counter()
    tasks = set()
    for report in root.glob('consumer-mod/build/test-results/testAddon_*/TEST-*.xml'):
        task = ':consumer-mod:' + report.parent.name
        tasks.add(task)
        tree = ET.parse(report)
        for case in tree.iter('testcase'):
            cases[(task, case.get('classname'), case.get('name'), case.find('skipped') is not None)] += 1
    return tasks, cases


def verify(baseline, observed, repository, baseline_log):
    assert not (baseline / 'build/addon-test-observability').exists(), 'Opt-out baseline must not emit observation metadata'
    directory = observed / 'build/addon-test-observability/dependencies'
    records = [json.loads(line) for line in (directory / 'dependencies.jsonl').read_text().splitlines()]
    expected = {'ru.thedevs:itink-tests:1.0.0', 'ru.thedevs:topodep-tests:1.0.0',
                'ru.thedevs:hostruntime-lib-tests:1.0.0', 'ru.thedevs:sample-lib-tests:1.0.0'}
    assert {record['coordinate'] for record in records if record['state'] == 'discovered'} == expected, records
    assert all(record['project'] == ':consumer-mod' for record in records), records
    allowed = {'discovered', 'artifact-resolved', 'descriptor-disabled', 'missing-artifact-pre-rollout'}
    assert all(record['state'] in allowed for record in records), records
    assert {record['coordinate'] for record in records if record['state'] == 'missing-artifact-pre-rollout'} == {'ru.thedevs:sample-lib-tests:1.0.0'}, records
    disabled = set()
    for coordinate in sorted(expected - {'ru.thedevs:sample-lib-tests:1.0.0'}):
        group, artifact, version = coordinate.split(':')
        jar = repository / group.replace('.', '/') / artifact / version / f'{artifact}-{version}.jar'
        artifact_records = [record for record in records if record['coordinate'] == coordinate and record['state'] == 'artifact-resolved']
        assert len(artifact_records) == 1, artifact_records
        assert artifact_records[0]['sha256'] == hashlib.sha256(jar.read_bytes()).hexdigest(), artifact_records
        with zipfile.ZipFile(jar) as archive:
            descriptor = archive.read('META-INF/thedevs-test.properties').decode('ISO-8859-1')
        if re.search(r'^thedevs\.tests\.disabled=true\s*$', descriptor, re.M):
            disabled.add(coordinate)
    assert disabled, 'Fixture must cover descriptor-disabled state'
    assert {record['coordinate'] for record in records if record['state'] == 'descriptor-disabled'} == disabled, records
    manifest = json.loads((directory / 'manifest.json').read_text())
    assert manifest['phase'] == 'complete' and manifest['lane'] == 'dependencies', manifest
    tasks = {task['path']: task for task in manifest['tasks']}
    original_graph = set(re.findall(r'^> Task (:[^\s]+:testAddon_[^\s]+)', baseline_log.read_text(), re.M))
    assert original_graph == {':consumer-mod:testAddon_itink', ':consumer-mod:testAddon_topodep', ':consumer-mod:testAddon_hostruntime-lib'}, original_graph
    assert set(tasks) == original_graph | {':consumer-mod:testAddon_sample-lib'}, tasks
    for coordinate in expected:
        artifact = coordinate.split(':')[1].removesuffix('-tests')
        state = tasks[':consumer-mod:testAddon_' + artifact]['state']
        assert state == ('skipped' if coordinate in disabled or artifact == 'sample-lib' else 'success'), (coordinate, state)
    before_tasks, before_cases = inventory(baseline)
    after_tasks, after_cases = inventory(observed)
    assert before_tasks and before_cases, 'Original fixture must actually execute dependency tests'
    assert before_tasks == after_tasks, (before_tasks, after_tasks)
    assert before_cases == after_cases, (before_cases - after_cases, after_cases - before_cases)
    return {'candidates': len(expected), 'disabled': len(disabled), 'executedTasks': len(after_tasks), 'cases': sum(after_cases.values())}


class ObservationAssertions(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.baseline = self.root / 'before'; self.observed = self.root / 'after'; self.repository = self.root / 'repo'
        directory = self.observed / 'build/addon-test-observability/dependencies'; directory.mkdir(parents=True)
        self.journal = directory / 'dependencies.jsonl'
        records, tasks = [], []
        for artifact in ('itink', 'topodep', 'hostruntime-lib', 'sample-lib'):
            coordinate = f'ru.thedevs:{artifact}-tests:1.0.0'
            records.append({'project': ':consumer-mod', 'coordinate': coordinate, 'state': 'discovered'})
            state = 'success' if artifact == 'itink' else 'skipped'
            tasks.append({'path': ':consumer-mod:testAddon_' + artifact, 'state': state})
            if artifact == 'sample-lib':
                records.append({'project': ':consumer-mod', 'coordinate': coordinate, 'state': 'missing-artifact-pre-rollout'})
                continue
            jar = self.repository / 'ru/thedevs' / f'{artifact}-tests' / '1.0.0' / f'{artifact}-tests-1.0.0.jar'
            jar.parent.mkdir(parents=True)
            with zipfile.ZipFile(jar, 'w') as archive:
                archive.writestr('META-INF/thedevs-test.properties', 'thedevs.tests.disabled=' + ('false' if artifact == 'itink' else 'true') + '\n')
            records.append({'project': ':consumer-mod', 'coordinate': coordinate, 'state': 'artifact-resolved', 'sha256': hashlib.sha256(jar.read_bytes()).hexdigest()})
            if artifact != 'itink':
                records.append({'project': ':consumer-mod', 'coordinate': coordinate, 'state': 'descriptor-disabled'})
        self.records = records
        self.save()
        (directory / 'manifest.json').write_text(json.dumps({'lane': 'dependencies', 'phase': 'complete', 'tasks': tasks}))
        self.log = self.root / 'baseline.log'
        self.log.write_text('\n'.join('> Task :consumer-mod:testAddon_' + artifact + (' SKIPPED' if artifact != 'itink' else '') for artifact in ('itink', 'topodep', 'hostruntime-lib')))
        for root in (self.baseline, self.observed):
            report = root / 'consumer-mod/build/test-results/testAddon_itink/TEST-a.xml'
            report.parent.mkdir(parents=True)
            report.write_text('<testsuite><testcase classname="Example" name="case[1]"/><testcase classname="Example" name="case[2]"><skipped/></testcase></testsuite>')

    def save(self):
        self.journal.write_text(''.join(json.dumps(record) + '\n' for record in self.records))

    def check(self):
        return verify(self.baseline, self.observed, self.repository, self.log)

    def test_unchanged_cases_states_and_artifact_checksums(self):
        self.assertEqual(2, self.check()['cases'])

    def test_modified_checksum_is_rejected(self):
        next(record for record in self.records if record['state'] == 'artifact-resolved')['sha256'] = '0' * 64
        self.save()
        with self.assertRaises(AssertionError): self.check()

    def test_missing_reason_or_candidate_is_rejected(self):
        self.records = [record for record in self.records if record['state'] != 'missing-artifact-pre-rollout']
        self.save()
        with self.assertRaises(AssertionError): self.check()

    def test_case_skip_drift_is_rejected(self):
        report = next(self.observed.glob('consumer-mod/build/test-results/testAddon_*/TEST-*.xml'))
        report.write_text(report.read_text().replace('<skipped/>', ''))
        with self.assertRaises(AssertionError): self.check()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--self-test':
        unittest.main(argv=[sys.argv[0]] + sys.argv[2:])
    else:
        print(json.dumps(verify(*(Path(value) for value in sys.argv[1:5])), sort_keys=True))
