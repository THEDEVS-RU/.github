#!/usr/bin/env python3
"""Offline, fail-closed report preparation. No external package or network access."""
import collections
import datetime
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
from urllib.parse import unquote, urlsplit
import xml.parsers.expat as expat


class Unsafe(ValueError):
    pass


def safe_display(value):
    value = re.sub(r'[\x00-\x1f\x7f]', '', str(value))[:180]
    # Encode source characters once, so entities generated for HTML are never re-escaped.
    return ''.join('&#' + str(ord(char)) + ';' if char in "&<>\"'\\`*_[]()#!+-.|:" else char for char in value)


def relative_path(value):
    if not value or '\\' in value or re.search(r'[*?\[\]{}\x00-\x1f]', value):
        raise Unsafe('invalid report path')
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or '.' in path.parts:
        raise Unsafe('invalid report path')
    return path


def conventional(path):
    text = str(path)
    return bool(re.fullmatch(r'(?:[^/]+/)*build/(?:test-results(?:/[^/]+)*|reports/tests(?:/[^/]+)*|reports/profile(?:/[^/]+)*|addon-test-observability/(?:own|dependencies)(?:/[^/]+)*)', text))


def prohibited_report_name(name):
    lowered = name.lower()
    return (
        lowered.startswith('.')
        or Path(lowered).stem in {'credentials', 'credential', 'kubeconfig', 'environment', 'env', 'system-properties', 'system_properties'}
        or lowered in {'gradle.properties', 'application.properties', 'application.yml', 'application.yaml'}
        or lowered.endswith(('.env', '.pem', '.key', '.jks', '.log', '.properties'))
    )


def checked(checkout, relative):
    path = checkout
    for part in relative.parts:
        if prohibited_report_name(part):
            raise Unsafe('prohibited credential/environment report path')
        path = path / part
        if path.is_symlink():
            raise Unsafe('symlink report path')
    if not path.resolve().is_relative_to(checkout):
        raise Unsafe('report outside checkout')
    return path


def open_report(checkout, relative):
    descriptor = os.open(checkout, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.parts[:-1]:
            next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor); descriptor = next_descriptor
        result = os.open(relative.parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        if not stat.S_ISREG(os.fstat(result).st_mode):
            os.close(result); raise Unsafe('nonregular report file')
        return os.fdopen(result, 'rb')
    finally:
        os.close(descriptor)


def report_entries(checkout, root):
    descriptor = os.open(checkout, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in root.parts:
            next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor); descriptor = next_descriptor
        for parent, directories, names, parent_descriptor in os.fwalk('.', dir_fd=descriptor, follow_symlinks=False):
            for name in directories + names:
                metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
                if stat.S_ISLNK(metadata.st_mode):
                    raise Unsafe('symlink report descendant')
                if name in directories:
                    if prohibited_report_name(name):
                        raise Unsafe('prohibited report directory')
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    raise Unsafe('nonregular report file')
                yield root / PurePosixPath(parent) / name
    finally:
        os.close(descriptor)


def permitted_file(path):
    if prohibited_report_name(path.name):
        raise Unsafe('prohibited credential/environment report file')
    if path.suffix.lower() not in {'.xml', '.html', '.htm', '.css', '.js', '.json', '.jsonl', '.png', '.svg', '.gif', '.ico', '.woff', '.woff2', '.ttf'}:
        raise Unsafe('unexpected report file type')


def parse_xml(path):
    cases = collections.Counter()
    classes, starts, cache = set(), set(), {}
    stack, output, pending = [], False, ''
    parser = expat.ParserCreate()
    def prohibited(*args):
        raise Unsafe('XML declarations prohibited')
    parser.StartDoctypeDeclHandler = prohibited
    parser.EntityDeclHandler = prohibited
    parser.ExternalEntityRefHandler = prohibited
    def start(name, attrs):
        nonlocal output
        if name == 'testcase':
            stack.append([attrs.get('classname', 'unavailable'), 'passed'])
        elif name in {'failure', 'error', 'skipped'} and stack:
            stack[-1][1] = 'skipped' if name == 'skipped' else 'failed'
        elif name == 'system-out':
            output = True
    def observe(line):
        found = re.search(r'DefaultContextCache@([\w]+).*?size\s*=\s*(\d+).*?hitCount\s*=\s*(\d+).*?missCount\s*=\s*(\d+)', line)
        if found:
            key, size, hits, misses = found.groups()
            old = cache.get(key)
            cache[key] = {'size': int(size), 'hits': int(hits), 'misses': int(misses), 'resets': (old or {}).get('resets', 0) + int(bool(old and (int(hits) < old['hits'] or int(misses) < old['misses'])))}
        found = re.search(r'Started ([\w.$]+) in ([\d.]+) seconds', line)
        if found:
            starts.add(found.groups())
    def data(text):
        nonlocal pending
        if output:
            for line in (pending + text).splitlines(keepends=True):
                if line.endswith(('\n', '\r')):
                    observe(line); pending = ''
                else:
                    pending = line[-4096:]
    def end(name):
        nonlocal output, pending
        if name == 'testcase':
            classname, state = stack.pop(); classes.add(classname); cases[state] += 1
        elif name == 'system-out':
            observe(pending); pending = ''; output = False
    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = data
    with path.open('rb') as stream:
        while chunk := stream.read(65536):
            parser.Parse(chunk, False)
        parser.Parse(b'', True)
    return dict(cases), classes, cache, sorted(starts)


def validate_html_assets(staging, report, root, files):
    class References(HTMLParser):
        def handle_starttag(self, tag, attributes):
            for name, value in attributes:
                if name not in {'href', 'src'} or not value:
                    continue
                url = urlsplit(html.unescape(value))
                if url.scheme in {'http', 'https', 'mailto', 'data'} or url.netloc:
                    continue
                if url.scheme:
                    raise Unsafe('unsafe report asset URL')
                path = unquote(url.path)
                if not path:
                    continue
                if path.startswith('/') or '\\' in path:
                    raise Unsafe('unsafe report asset path')
                target = (report.parent / path).resolve()
                if not target.is_relative_to(staging / root):
                    raise Unsafe('report asset outside report tree')
                if str(target.relative_to(staging)) not in files:
                    raise ValueError('missing referenced report asset')
    parser = References(convert_charrefs=True)
    with report.open(encoding='utf-8', errors='strict') as source:
        while chunk := source.read(65536):
            parser.feed(chunk)
    parser.close()


def collect(env):
    checkout = Path(env.get('GITHUB_WORKSPACE', os.getcwd())).resolve()
    staging = Path(tempfile.mkdtemp(prefix='addon-tests-', dir=env['RUNNER_TEMP']))
    errors, unsafe, files, tasks = [], False, {}, []
    counts = collections.Counter()
    lane = env.get('REPORT_LANE', '')
    manifest = {}
    secret_values = [env[key].encode() for key in ('REPORT_SECRET_USER', 'REPORT_SECRET_PASSWORD') if env.get(key)]
    try:
        if lane not in {'own', 'dependencies'}:
            raise Unsafe('invalid lane')
        roots = [relative_path(x.strip()) for x in env.get('REPORT_ROOTS', '').splitlines() if x.strip()]
        if not roots or any(not conventional(x) for x in roots):
            raise Unsafe('invalid report root type')
        for root in roots:
            directory = checked(checkout, root)
            if not directory.exists():
                continue
            if not directory.is_dir():
                raise Unsafe('report root is not directory')
            for relative in report_entries(checkout, root):
                    candidate = checkout / relative
                    if '/test-results/' in str(relative) and 'binary' in relative.parts and candidate.name in {'output.bin', 'output.bin.idx', 'results.bin', 'results-generic.bin', 'output-events.bin'}:
                        continue
                    permitted_file(candidate)
                    # Scan across chunk boundaries without printing contents or the matched value.
                    overlap = max([len(x) for x in secret_values] + [1]) - 1
                    tail = b''
                    target = staging / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with open_report(checkout, relative) as stream, target.open('wb') as copied:
                        while chunk := stream.read(65536):
                            data = tail + chunk
                            if any(value in data for value in secret_values):
                                raise Unsafe('credential-content error')
                            tail = data[-overlap:] if overlap else b''
                            copied.write(chunk)
                    files[str(relative)] = target
        manifest_path = relative_path(env.get('REPORT_MANIFEST', ''))
        if str(manifest_path) != f'build/addon-test-observability/{lane}/manifest.json':
            raise Unsafe('unexpected manifest location')
        if not any(manifest_path.is_relative_to(root) for root in roots):
            raise Unsafe('manifest outside roots')
        if str(manifest_path) not in files:
            errors.append('missing manifest')
        else:
            manifest = json.loads(files[str(manifest_path)].read_text())
            if not isinstance(manifest, dict):
                manifest = {}; raise ValueError('invalid manifest')
            if 'elapsedNanos' in manifest and (not isinstance(manifest['elapsedNanos'], (int, float)) or manifest['elapsedNanos'] < 0):
                raise ValueError('invalid phase duration')
            if manifest.get('schemaVersion') != 1 or manifest.get('lane') != lane:
                errors.append('invalid manifest schema/lane')
            tasks = manifest.get('tasks', [])
            if not isinstance(tasks, list):
                raise ValueError('invalid task list')
            if not tasks and env.get('REPORT_TEST_OUTCOME') == 'success':
                errors.append('empty scheduled test inventory')
            seen = set(); used_locations = set(); xml_owners = collections.Counter()
            if any(not isinstance(task, dict) for task in tasks):
                tasks = []; raise ValueError('invalid task record')
            for task in tasks:
                identity = task['path']
                if not isinstance(identity, str):
                    raise ValueError('invalid task identity')
                for key in ('project', 'build'):
                    value = task.get(key)
                    if value is not None and value != '':
                        checked(checkout, relative_path(value))
                if 'elapsedNanos' in task and (not isinstance(task['elapsedNanos'], (int, float)) or task['elapsedNanos'] < 0):
                    task.pop('elapsedNanos', None); raise ValueError('invalid task duration')
                if task.get('counts') is not None and (not isinstance(task['counts'], dict) or any(not isinstance(v, int) or v < 0 for v in task['counts'].values())):
                    raise ValueError('invalid task counts')
                if task.get('state') not in {'success', 'failure', 'no-source', 'skipped', 'running', 'scheduled'}:
                    errors.append('unknown task state')
                if identity in seen:
                    errors.append('duplicate task identity')
                seen.add(identity)
                task_counts, classes, caches, starts = collections.Counter(), set(), {}, []
                for kind in ('xml', 'html'):
                    location = relative_path(task[kind])
                    expected_kind = '/build/test-results/' if kind == 'xml' else '/build/reports/tests/'
                    if expected_kind not in '/' + str(location) + '/':
                        raise Unsafe('manifest report kind mismatch')
                    if (kind, str(location)) in used_locations:
                        errors.append('duplicate task report location')
                    if any(previous_kind == kind and (location.is_relative_to(PurePosixPath(previous)) or PurePosixPath(previous).is_relative_to(location)) for previous_kind, previous in used_locations):
                        errors.append('overlapping task report locations')
                    used_locations.add((kind, str(location)))
                    if not conventional(location) or not any(location.is_relative_to(root) for root in roots):
                        raise Unsafe('manifest report outside roots')
                    checked(checkout, location)
                    available = [path for name, path in files.items() if PurePosixPath(name).is_relative_to(location)]
                    if task.get('state') in {'success', 'failure'} and not available:
                        errors.append('missing executed-task ' + kind)
                    if kind == 'html' and task.get('state') in {'success', 'failure'}:
                        index = str(location / 'index.html')
                        if index not in files:
                            errors.append('missing executed-task HTML index')
                        for path in available:
                            if path.suffix.lower() in {'.html', '.htm'}:
                                validate_html_assets(staging, path, location, files)
                    if kind == 'xml':
                        for path in available:
                            if path.suffix == '.xml':
                                xml_owners[str(path.relative_to(staging))] += 1
                                parsed, names, cache, startup = parse_xml(path)
                                task_counts.update(parsed); classes.update(names)
                                # Cache identities are scoped to task AND XML worker report. Never sum counters.
                                caches[str(path.relative_to(staging))] = cache
                                starts.extend(startup)
                observed = task.get('counts')
                if observed is not None and any(task_counts[key] != observed.get(key, 0) for key in ('passed', 'failed', 'skipped')):
                    errors.append('manifest/report count mismatch')
                if task.get('state') in {'no-source', 'skipped'} and sum(task_counts.values()):
                    errors.append('reports for unexecuted task')
                if task.get('state') in {'running', 'scheduled'}:
                    errors.append('incomplete task')
                if task.get('state') in {'success', 'failure'} and sum(task_counts.values()) == 0:
                    errors.append('executed-empty task')
                task['reportCounts'] = {key: task_counts[key] for key in ('passed', 'failed', 'skipped')}
                task['distinctClasses'] = len(classes)
                task['cacheStatisticsByReport'] = caches
                cache_observations = {}
                for report_cache in caches.values():
                    for cache_id, observation in report_cache.items():
                        previous = cache_observations.get(cache_id)
                        if previous is None or (observation['misses'], observation['hits']) > (previous['misses'], previous['hits']):
                            cache_observations[cache_id] = observation
                task['cacheDeduplicatedObservations'] = cache_observations
                task['cacheScope'] = 'report-local observations; JVM identity unavailable; do not sum across reports'
                task['contextStarts'] = sorted(set(tuple(x) for x in starts))
                counts.update(task_counts)
            if any(xml_owners[name] != 1 for name in files if '/test-results/' in name and name.endswith('.xml')):
                errors.append('unowned or duplicate XML report')
            if manifest.get('phase') not in {'complete', 'failure'}:
                errors.append('incomplete phase')
        for name, path in files.items():
            if name.startswith('build/reports/profile/') and path.suffix.lower() in {'.html', '.htm'}:
                validate_html_assets(staging, path, PurePosixPath('build/reports/profile'), files)
        if not any(name.startswith('build/reports/profile/') and name.endswith('.html') for name in files):
            errors.append('missing Gradle profile')
        if env.get('REPORT_TEST_OUTCOME') not in {'success', 'failure'}:
            errors.append('test command incomplete')
    except Unsafe as exc:
        unsafe = True; errors.append(str(exc))
    except OSError:
        unsafe = True; errors.append('unsafe or unreadable report path')
    except (ValueError, KeyError, TypeError, AttributeError, UnicodeError, expat.ExpatError):
        tasks = []; manifest = {}; counts.clear()
        errors.append('malformed or unreadable report metadata/XML')
    if unsafe:
        tasks = []; counts.clear(); manifest = {}
    status = {'schemaVersion': 1, 'testOutcome': env.get('REPORT_TEST_OUTCOME', 'unknown'), 'complete': not errors, 'errors': sorted(set(errors)), 'tasks': tasks, 'counts': {key: counts[key] for key in ('passed', 'failed', 'skipped')} if tasks else None, 'fileCount': len(files), 'bytes': sum(p.stat().st_size for p in files.values())}
    if not unsafe:
        (staging / 'collection-status.json').write_text(json.dumps(status, sort_keys=True))
    else:
        shutil.rmtree(staging)
    identity = '-'.join(re.sub(r'[^A-Za-z0-9_-]', '-', env.get(key, 'unknown'))[:80] for key in ('GITHUB_REPOSITORY', 'REPORT_RUN_ID', 'REPORT_RUN_ATTEMPT', 'GITHUB_JOB', 'REPORT_LANE'))
    prepared = datetime.datetime.now(datetime.timezone.utc).isoformat()
    lines = ['### Addon tests ' + safe_display(lane), 'Test outcome: ' + safe_display(status['testOutcome']), 'Head/action: ' + safe_display(env.get('REPORT_HEAD_SHA')) + ' / ' + safe_display(env.get('REPORT_ACTION_SHA')), 'Run/attempt: ' + safe_display(env.get('REPORT_RUN_ID')) + '/' + safe_display(env.get('REPORT_RUN_ATTEMPT')), 'Phase wall seconds: ' + safe_display(manifest.get('elapsedNanos', 'unavailable') / 1e9 if isinstance(manifest.get('elapsedNanos'), (int, float)) else 'unavailable'), 'Cases passed/failed/skipped: ' + ('/'.join(str(counts[x]) for x in ('passed', 'failed', 'skipped')) if tasks else 'unavailable')]
    for task in tasks[:10]:
        lines.append('Task ' + safe_display(task.get('path')) + ': ' + safe_display(task.get('state')) + ', counts=' + safe_display(task.get('reportCounts', {})) + ', classes=' + str(task.get('distinctClasses', 'unavailable')) + ', seconds=' + str(task.get('elapsedNanos', 0) / 1e9 if 'elapsedNanos' in task else 'unavailable'))
        lines.append('Cache/startup (task/report scope): ' + safe_display(task.get('cacheDeduplicatedObservations') or 'unavailable/partial') + ' (cache identity; JVM unavailable/partial, reset ordering unavailable)'  + ' / ' + safe_display(task.get('contextStarts') or 'unavailable'))
    if len(tasks) > 10:
        lines.append('Task display omitted: ' + str(len(tasks) - 10))
    suite_file = next((path for name, path in files.items() if name.endswith('/suites.jsonl')), None)
    if suite_file and not unsafe:
        try:
            slow = []
            with suite_file.open() as stream:
                for line in stream:
                    record = json.loads(line)
                    if not isinstance(record, dict) or not isinstance(record.get('durationMillis', 0), (int, float)):
                        raise ValueError('invalid suite record')
                    if record.get('className'):
                        slow.append(record)
            for record in sorted(slow, key=lambda x: x.get('durationMillis', 0), reverse=True)[:10]:
                lines.append('Slow suite (overlaps wall): ' + safe_display(record.get('task')) + ' / ' + safe_display(record.get('className')) + ' ' + str(record.get('durationMillis', 'unavailable')) + 'ms')
        except (ValueError, TypeError, AttributeError, OSError):
            errors.append('invalid suite timing metadata'); status['complete'] = False
    lines.extend(['Files/bytes: ' + str(status['fileCount']) + '/' + str(status['bytes']), 'Reports: ' + ('complete' if status['complete'] else safe_display(', '.join(sorted(set(errors))))), 'Prepared at: ' + prepared])
    if not unsafe:
        status['errors'] = sorted(set(errors))
        (staging / 'collection-status.json').write_text(json.dumps(status, sort_keys=True))
    raw_summary = '\n'.join(lines[:78]).encode('utf-8')
    summary = raw_summary[:15800].decode('utf-8', errors='ignore') + '\n'
    if len(raw_summary) > 15800 or len(lines) > 78:
        summary += 'Display truncated; complete safe metadata retained. Omitted bytes: ' + str(max(0, len(raw_summary) - 15800)) + '\n'
    for value in secret_values:
        summary = summary.replace(value.decode('utf-8', errors='replace'), '[credential omitted]')
    print(summary, flush=True)
    if env.get('GITHUB_STEP_SUMMARY'):
        with open(env['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write(summary)
    outputs = {'artifact-path': str(staging) if not unsafe else '', 'artifact-name': 'addon-tests-' + identity, 'ready': str(not unsafe).lower(), 'complete': str(status['complete']).lower(), 'prepared-at': prepared}
    if env.get('GITHUB_OUTPUT'):
        with open(env['GITHUB_OUTPUT'], 'a') as output:
            for key, value in outputs.items():
                output.write(key + '=' + value + '\n')
    return 0 if status['complete'] else 1


if __name__ == '__main__':
    sys.exit(collect(os.environ))
