#!/usr/bin/env python3
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout

spec = importlib.util.spec_from_file_location('collector', Path(__file__).parents[1] / 'actions/collect-addon-test-reports/collect-reports.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class Reports(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.checkout = self.base / 'checkout'; self.checkout.mkdir()
        self.runner = self.base / 'runner'; self.runner.mkdir()
        self.env = {'GITHUB_WORKSPACE': str(self.checkout), 'RUNNER_TEMP': str(self.runner),
            'GITHUB_OUTPUT': str(self.base / 'output'), 'GITHUB_STEP_SUMMARY': str(self.base / 'summary'),
            'REPORT_LANE': 'own', 'REPORT_MANIFEST': 'build/addon-test-observability/own/manifest.json',
            'REPORT_TEST_OUTCOME': 'success', 'REPORT_ROOTS': 'module/build/test-results\nmodule/build/reports/tests\nbuild/reports/profile\nbuild/addon-test-observability/own',
            'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_JOB': 'test-own', 'REPORT_RUN_ID': '12',
            'REPORT_RUN_ATTEMPT': '1', 'REPORT_HEAD_SHA': 'a'*40, 'REPORT_ACTION_SHA': 'b'*40}
        self.task = {'path': ':module:headlessTest', 'state': 'success', 'xml': 'module/build/test-results/headlessTest', 'html': 'module/build/reports/tests/headlessTest', 'counts': {'passed': 1, 'failed': 0, 'skipped': 1}}
        self.write('module/build/test-results/headlessTest/TEST-a.xml', '<testsuite><testcase classname="A" name="parameter[1]"/><testcase classname="A" name="parameter[2]"><skipped/></testcase></testsuite>')
        self.write('module/build/reports/tests/headlessTest/index.html', '<html>report</html>')
        self.write('module/build/reports/tests/headlessTest/css/base.css', 'body{}')
        self.write('build/reports/profile/profile.html', '<html>profile</html>')
        self.manifest()

    def write(self, name, text):
        path = self.checkout / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text); return path

    def manifest(self):
        self.write(self.env['REPORT_MANIFEST'], json.dumps({'schemaVersion': 1, 'lane': 'own', 'phase': 'complete', 'tasks': [self.task]}))

    def collect(self):
        with redirect_stdout(io.StringIO()) as output:
            result = collector.collect(self.env)
        values = dict(line.split('=', 1) for line in Path(self.env['GITHUB_OUTPUT']).read_text().splitlines())
        return result, values, output.getvalue()

    def test_malformed_metadata_always_produces_summary_and_outputs(self):
        for manifest in ([], {'tasks': 3}, {'tasks': [{}]}, {'schemaVersion': 1, 'lane': 'own', 'tasks': [dict(self.task, elapsedNanos='bad')]}, {'schemaVersion': 1, 'lane': 'own', 'tasks': [dict(self.task, counts=[])]}):
            self.write(self.env['REPORT_MANIFEST'], json.dumps(manifest))
            result, values, summary = self.collect()
            self.assertEqual(1, result); self.assertEqual('false', values['complete']); self.assertIn('Reports:', summary)
        self.manifest()
        self.write('build/addon-test-observability/own/suites.jsonl', '{"className":"A","durationMillis":"bad"}\n')
        self.assertEqual('false', self.collect()[1]['complete'])

    def test_setup_exports_optional_observation_without_changing_strict(self):
        import subprocess
        action = Path(__file__).parents[1] / 'actions/setup-addon-tests/action.yml'
        shell = '\n'.join(line[8:] for line in action.read_text().split('      run: |\n', 1)[1].splitlines())
        for observation, strict in itertools.product(('false', 'true'), repeat=2):
            output = self.base / 'setup-output'; output.write_text('')
            environment = self.base / 'setup-env'; environment.write_text('')
            result = subprocess.run(['bash', '-e', '-c', shell], env=dict(os.environ, ACTION_PATH=str(action.parent), OBSERVABILITY_INPUT=observation, STRICT_INPUT=strict, THEDEVS_TESTS_STRICT='false', GITHUB_OUTPUT=str(output), GITHUB_ENV=str(environment)), capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(observation == 'true', 'THEDEVS_ADDON_TESTS_OBSERVABILITY_INIT=' in environment.read_text())
            self.assertEqual(strict == 'true', 'THEDEVS_TESTS_STRICT=true' in environment.read_text())
            self.assertIn('THEDEVS_ADDON_TESTS_INIT=', environment.read_text())

    def test_executed_html_requires_index_and_referenced_assets(self):
        index = self.checkout / 'module/build/reports/tests/headlessTest/index.html'
        index.unlink()
        self.assertEqual('false', self.collect()[1]['complete'])
        index.write_text('<html><link href="css/missing.css"></html>')
        self.assertEqual('false', self.collect()[1]['complete'])
        self.write('module/build/reports/tests/headlessTest/css/missing.css', 'body{}')
        self.assertEqual('true', self.collect()[1]['complete'])
        index.write_text('<html><img src="../../../../outside.png"></html>')
        self.assertEqual('false', self.collect()[1]['ready'])

    def test_profile_referenced_assets_required(self):
        self.write('build/reports/profile/profile.html', '<html><script src="js/profile.js"></script></html>')
        self.assertEqual('false', self.collect()[1]['complete'])
        self.write('build/reports/profile/js/profile.js', 'const profile = 1;')
        self.assertEqual('true', self.collect()[1]['complete'])

    def test_failure_with_non_xml_output_is_incomplete(self):
        (self.checkout / 'module/build/test-results/headlessTest/TEST-a.xml').unlink()
        self.write('module/build/test-results/headlessTest/status.json', '{}')
        self.task.update(state='failure', counts=None); self.manifest()
        self.env['REPORT_TEST_OUTCOME'] = 'failure'
        self.assertEqual('false', self.collect()[1]['complete'])

    def test_credential_and_environment_names_rejected_without_values(self):
        for name in ('credentials.json', 'kubeconfig.xml', 'environment.json', 'system-properties.json'):
            path = self.write('module/build/reports/tests/headlessTest/' + name, '{}')
            self.assertEqual('false', self.collect()[1]['ready'])
            path.unlink()

    def test_binary_outputs_are_never_staged(self):
        self.write('module/build/test-results/headlessTest/binary/output.bin', 'binary')
        result, values, _ = self.collect()
        self.assertEqual(0, result)
        self.assertFalse((Path(values['artifact-path']) / 'module/build/test-results/headlessTest/binary/output.bin').exists())

    def test_complete_raw_nested_assets_and_skip_counts(self):
        result, values, summary = self.collect()
        self.assertEqual(0, result); self.assertEqual('true', values['ready']); self.assertEqual('true', values['complete'])
        staging = Path(values['artifact-path'])
        self.assertEqual((self.checkout / 'module/build/test-results/headlessTest/TEST-a.xml').read_bytes(), (staging / 'module/build/test-results/headlessTest/TEST-a.xml').read_bytes())
        self.assertTrue((staging / 'module/build/reports/tests/headlessTest/css/base.css').exists())
        self.assertIn('1/0/1', summary)

    def test_missing_malformed_and_empty_xml(self):
        xml = self.checkout / 'module/build/test-results/headlessTest/TEST-a.xml'
        for content in ('<bad', '<testsuite/>'):
            xml.write_text(content)
            result, values, _ = self.collect()
            self.assertEqual(1, result); self.assertEqual('true', values['ready']); self.assertEqual('false', values['complete'])
        xml.unlink()
        self.assertEqual(1, self.collect()[0])

    def test_paths_symlinks_and_secret_never_uploaded(self):
        original = self.env['REPORT_ROOTS']
        for path in ('/tmp', '../neighbor', 'module/build/*', 'module/build/addon-tests', '.'):
            self.env['REPORT_ROOTS'] = path
            result, values, _ = self.collect()
            self.assertEqual(1, result); self.assertEqual('false', values['ready'])
        self.env['REPORT_ROOTS'] = original
        link = self.checkout / 'module/build/reports/tests/headlessTest/linked.html'
        link.symlink_to(self.base / 'unrelated')
        self.assertEqual('false', self.collect()[1]['ready']); link.unlink()
        self.env['REPORT_SECRET_PASSWORD'] = 'synthetic-secret-value'
        self.write('module/build/reports/tests/headlessTest/index.html', 'synthetic-secret-value')
        result, values, summary = self.collect()
        self.assertEqual('false', values['ready']); self.assertNotIn('synthetic-secret-value', summary)

    def test_dtd_and_entity_rejected(self):
        self.write('module/build/test-results/headlessTest/TEST-a.xml', '<!DOCTYPE test [<!ENTITY x SYSTEM "file:///etc/passwd">]><testsuite>&x;</testsuite>')
        self.assertEqual('false', self.collect()[1]['ready'])

    def test_manifest_outside_allowlist_and_missing_profile(self):
        self.task['xml'] = 'neighbor/build/test-results/test'; self.manifest()
        self.assertEqual('false', self.collect()[1]['ready'])
        self.task['xml'] = 'module/build/test-results/headlessTest'; self.manifest()
        (self.checkout / 'build/reports/profile/profile.html').unlink()
        self.assertEqual('false', self.collect()[1]['complete'])

    def test_report_failures_preserve_test_failure_and_attempt_uniqueness(self):
        self.env['REPORT_TEST_OUTCOME'] = 'failure'
        result, first, summary = self.collect()
        self.assertEqual(0, result); self.assertIn('Test outcome: failure', summary)
        self.env['REPORT_RUN_ATTEMPT'] = '2'
        second = self.collect()[1]
        self.assertNotEqual(first['artifact-name'], second['artifact-name'])
        self.assertNotEqual(first['artifact-path'], second['artifact-path'])

    def test_no_source_separate_from_executed_empty_and_hostile_display(self):
        (self.checkout / 'module/build/test-results/headlessTest/TEST-a.xml').unlink()
        self.task.update(state='no-source', counts=None, path='::error::`<unsafe>|![x](https://example.test)\n')
        self.manifest()
        result, _, summary = self.collect()
        self.assertEqual(0, result)
        self.assertNotIn('::error::', summary); self.assertNotIn('<unsafe>', summary); self.assertNotIn('![x](', summary)
        self.assertLessEqual(len(summary.encode()), 16384); self.assertLessEqual(len(summary.splitlines()), 80)

    def test_stray_and_stale_xml_rejected(self):
        self.write('module/build/test-results/stray/TEST-other.xml', '<testsuite><testcase/></testsuite>')
        self.assertEqual('false', self.collect()[1]['complete'])
        (self.checkout / 'module/build/test-results/stray/TEST-other.xml').unlink()
        self.task.update(state='no-source', counts=None); self.manifest()
        self.assertEqual('false', self.collect()[1]['complete'])

    def test_nested_suite_counts_use_only_cases(self):
        self.write('module/build/test-results/headlessTest/TEST-a.xml', '<testsuites tests="4"><testsuite tests="2"><testcase classname="A" name="same"/><testsuite tests="1"><testcase classname="A" name="same"><skipped/></testcase></testsuite></testsuite></testsuites>')
        self.assertEqual(0, self.collect()[0])

    def test_cache_final_not_sum_and_resets(self):
        text = '<testsuite><testcase classname="A"/><testcase classname="A"><skipped/></testcase><system-out>DefaultContextCache@abc size = 1 hitCount = 3 missCount = 1\nDefaultContextCache@abc size = 1 hitCount = 4 missCount = 1\nDefaultContextCache@abc size = 1 hitCount = 1 missCount = 1</system-out></testsuite>'
        path = self.write('module/build/test-results/headlessTest/TEST-a.xml', text)
        _, _, cache, _ = collector.parse_xml(path)
        self.assertEqual({'size': 1, 'hits': 1, 'misses': 1, 'resets': 1}, cache['abc'])


if __name__ == '__main__':
    unittest.main()
