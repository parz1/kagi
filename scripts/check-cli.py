#!/usr/bin/env python3
"""CLI 回归检查；只使用临时目录、软件密钥和明显的假值。先运行 swift build。"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
KAGI = str(ROOT / '.build/debug/kagi')


class CLIFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='kagi-cli-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, KAGI_DEBUG_SOFTWARE_KEYS='1',
                        KAGI_DEBUG_AUTH_DECISION='approve',
                        KAGI_HOME=str(self.root / 'local'), NO_COLOR='1')
        result = self.call('_debug-init', '--vault', str(self.root / 'vault'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.recovery = result.stdout.decode().strip().split('恢复密钥（调试库，假的）：')[-1]

    def call(self, *args, data=None):
        return subprocess.run([KAGI, *args], input=data, env=self.env,
                              capture_output=True, timeout=20)

    def put(self, ref, value=b'FAKE-TOKEN-FOR-TEST'):
        result = self.call('set', ref, '--stdin', data=value)
        self.assertEqual(result.returncode, 0, result.stderr)

    def vault_snapshot(self):
        return {str(path.relative_to(self.root / 'vault')): path.read_bytes()
                for path in (self.root / 'vault').rglob('*') if path.is_file()}



class CLITests(CLIFixture):
    def test_cancelled_creation_and_overwrite_leave_vault_unchanged(self):
        self.put('demo/token')
        before = self.vault_snapshot()
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'deny'
        for ref in ['demo/new', 'demo/token']:
            result = self.call('set', ref, '--stdin', data=b'FAKE-CANCELLED-CHANGE')
            self.assertEqual(result.returncode, 77, result.stderr)
            self.assertEqual(self.vault_snapshot(), before)
            record = json.loads((self.root / 'local/log.jsonl').read_text().splitlines()[-1])
            self.assertEqual(record['action'], 'set')
            self.assertEqual(record['result'], 'denied')

    def test_cancelled_env_and_stdin_never_launch_command(self):
        self.put('demo/token')
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'deny'
        for injection in [['--env', 'DEMO=demo/token'], ['--stdin', 'demo/token']]:
            with self.subTest(injection=injection):
                marker = self.root / 'child-executed'
                # 使用独立标记文件确认子进程没有执行。
                result = self.call('run', *injection, '--', '/usr/bin/touch', str(marker))
                self.assertEqual(result.returncode, 77, result.stderr)
                self.assertFalse(marker.exists())
                record = json.loads((self.root / 'local/log.jsonl').read_text().splitlines()[-1])
                self.assertEqual(record['result'], 'denied')
                self.assertEqual(record['exitCode'], 77)

    def test_denial_does_not_block_metadata_or_prompt_for_it(self):
        self.put('demo/token')
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'deny'
        for args in [('ls',), ('where', 'demo/token')]:
            result = self.call(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('模拟授权说明：'.encode(), result.stderr)

    def test_locked_reads_writes_and_run_fail_without_mutation_or_execution(self):
        self.put('demo/token')
        before = self.vault_snapshot()
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'locked'
        marker = self.root / 'child-executed'
        for args, data in [
            (('ls',), None),
            (('set', 'demo/token', '--stdin'), b'FAKE-LOCKED-CHANGE'),
            (('run', '--env', 'DEMO=demo/token', '--', '/usr/bin/touch', str(marker)), None),
        ]:
            result = self.call(*args, data=data)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(self.vault_snapshot(), before)
        # 解锁是单独的新请求；之前被阻止的命令没有被自动重试。
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'approve'
        result = self.call('run', '--env', 'DEMO=demo/token', '--',
                           '/bin/sh', '-c', 'test "$DEMO" = FAKE-TOKEN-FOR-TEST')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_approval_description_contains_target_directory_and_injection(self):
        self.put('demo/token')
        result = self.call('run', '--env', 'DEMO=demo/token', '--', '/usr/bin/true')
        self.assertEqual(result.returncode, 0, result.stderr)
        description = result.stderr.decode()
        self.assertIn('模拟授权说明：', description)
        self.assertIn('/usr/bin/true', description)
        self.assertIn(os.getcwd(), description)
        self.assertIn('DEMO=demo/token', description)
        self.assertNotIn('FAKE-TOKEN-FOR-TEST', description)

    def test_mock_init_denial_and_lock_do_not_commit_vault_or_state(self):
        for decision, code in [('deny', 77), ('locked', 75)]:
            env = dict(self.env, KAGI_DEBUG_AUTH_DECISION=decision,
                       KAGI_HOME=str(self.root / ('local-' + decision)))
            vault = self.root / ('vault-' + decision)
            result = subprocess.run([KAGI, '_debug-init', '--vault', str(vault)],
                                    env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, code, result.stderr)
            self.assertFalse((vault / 'vault.json').exists())
            self.assertFalse((Path(env['KAGI_HOME']) / 'device.json').exists())

    def test_invalid_mock_decision_fails_without_writing(self):
        before = self.vault_snapshot()
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'typo'
        result = self.call('set', 'demo/new', '--stdin', data=b'FAKE-INVALID-DECISION')
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(self.vault_snapshot(), before)

    def test_mock_cancel_and_lock_do_not_repair_index(self):
        self.put('demo/token')
        next((self.root / 'vault/index').glob('*.kagi')).unlink()
        before = self.vault_snapshot()
        for decision, code in [('deny', 77), ('locked', 75)]:
            self.env['KAGI_DEBUG_AUTH_DECISION'] = decision
            result = self.call('repair-index')
            self.assertEqual(result.returncode, code, result.stderr)
            self.assertEqual(self.vault_snapshot(), before)
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'approve'
        self.assertEqual(self.call('repair-index').returncode, 0)
        self.assertEqual(self.call('ls').returncode, 0)

    def test_cancelled_write_audit_redacts_even_short_input(self):
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'deny'
        for value in ['FAKE-CANCELLED-WRITE', 'x']:
            command = ('printf %s ' + shlex.quote(value) + ' | ' + shlex.quote(KAGI)
                       + ' set demo/cancelled --stdin; result=$?; exit $result')
            result = subprocess.run(['/bin/zsh', '-c', command], env=self.env,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 77, result.stderr)
            record = json.loads((self.root / 'local/log.jsonl').read_text().splitlines()[-1])
            self.assertEqual(record['result'], 'denied')
            self.assertIsNotNone(record['fullCommand'])
            self.assertNotIn(value, record['fullCommand'])
            self.assertIn('‹kagi:demo/cancelled›', record['fullCommand'])

    def test_spaces_tags_edit_search_and_json_keep_reference_and_value(self):
        self.assertEqual(self.call('space', 'create', 'work', '--name', '工作').returncode, 0)
        result = self.call('set', 'demo/token', '--stdin', '--space', 'work',
                           '--title', '生产接口', '--tag', 'PROD', '--tag', 'api',
                           data=b'FAKE-MANAGED-TOKEN')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.call('ls', '--space', 'work', '--tag', 'prod', '--tag', 'api',
                           '--search', '生产', '--json')
        rows = json.loads(result.stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['record']['metadata']['tags'], ['api', 'prod'])
        self.assertNotIn(b'FAKE-MANAGED-TOKEN', result.stdout)
        entry = rows[0]['entry']
        result = self.call('edit', 'demo/token', '--space', 'default', '--title', '新的名字',
                           '--notes', '负责人已确认', '--clear-tags')
        self.assertEqual(result.returncode, 0, result.stderr)
        row = json.loads(self.call('where', 'demo/token', '--json').stdout)
        self.assertEqual(row['entry'], entry)
        self.assertEqual(row['record']['ref'], 'demo/token')
        self.assertEqual(row['record']['latestVersion'], 1)
        self.assertEqual(row['record']['metadata']['space'], 'default')
        self.assertEqual(row['record']['metadata']['tags'], [])
        self.assertEqual(json.loads(self.call('tags', '--json').stdout), [])
        result = self.call('run', '--env', 'DEMO=demo/token', '--', '/bin/sh', '-c',
                           'test "$DEMO" = FAKE-MANAGED-TOKEN')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call('space', 'remove', 'work').returncode, 0)

    def test_archive_excludes_run_and_restore_preserves_versions(self):
        self.put('demo/token')
        self.assertEqual(self.call('archive', 'demo/token').returncode, 0)
        self.assertEqual(json.loads(self.call('ls', '--json').stdout), [])
        archived = json.loads(self.call('ls', '--archived', '--json').stdout)
        self.assertEqual(len(archived), 1)
        result = self.call('run', '--env', 'DEMO=demo/token', '--', '/usr/bin/true')
        self.assertEqual(result.returncode, 66)
        result = self.call('set', 'demo/token', '--stdin', data=b'FAKE-BLOCKED-UPDATE')
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.call('restore', 'demo/token').returncode, 0)
        result = self.call('run', '--env', 'DEMO=demo/token', '--', '/bin/sh', '-c',
                           'test "$DEMO" = FAKE-TOKEN-FOR-TEST')
        self.assertEqual(result.returncode, 0, result.stderr)
        row = json.loads(self.call('where', 'demo/token', '--json').stdout)
        self.assertEqual(row['record']['latestVersion'], 1)

    def test_management_denial_and_lock_leave_catalog_and_index_unchanged(self):
        self.put('demo/token')
        self.assertEqual(self.call('space', 'create', 'work').returncode, 0)
        before = self.vault_snapshot()
        for decision, code in [('deny', 77), ('locked', 75)]:
            self.env['KAGI_DEBUG_AUTH_DECISION'] = decision
            for args in [('space', 'create', 'blocked'), ('space', 'rename', 'work', '--name', 'No'),
                         ('space', 'remove', 'work'), ('edit', 'demo/token', '--space', 'work'),
                         ('archive', 'demo/token')]:
                result = self.call(*args)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(self.vault_snapshot(), before)

    def test_readonly_management_with_denied_auth_does_not_prompt(self):
        self.put('demo/token')
        self.env['KAGI_DEBUG_AUTH_DECISION'] = 'deny'
        for args in [('space', 'ls', '--json'), ('tags', '--json'), ('ls', '--json'),
                     ('where', 'demo/token', '--json')]:
            result = self.call(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            json.loads(result.stdout)
            self.assertNotIn('模拟授权说明：'.encode(), result.stderr)

    def test_repair_missing_index_does_not_silently_reactivate_key(self):
        self.put('demo/token')
        self.assertEqual(self.call('archive', 'demo/token').returncode, 0)
        next((self.root / 'vault/index').glob('*.kagi')).unlink()
        self.assertEqual(self.call('repair-index').returncode, 0)
        self.assertEqual(json.loads(self.call('ls', '--json').stdout), [])
        rows = json.loads(self.call('ls', '--archived', '--json').stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['record']['metadata']['space'], 'default')
        self.assertEqual(self.call('run', '--env', 'DEMO=demo/token', '--', '/usr/bin/true').returncode, 66)

    def test_recovery_names_cannot_collide(self):
        expected = {'demo/foo': b'FAKE-FIRST', 'demo/foo.txt': b'FAKE-SECOND',
                    'demo/foo.txt/child': b'FAKE-THIRD'}
        for ref, value in expected.items():
            self.put(ref, value)
        result = subprocess.run(['swift', str(ROOT / 'recover/recover.swift'),
                                 '--vault', str(self.root / 'vault'),
                                 '--out', str(self.root / 'out')],
                                input=(self.recovery + '\n').encode(),
                                capture_output=True, timeout=30,
                                start_new_session=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.root / 'out/manifest.json').read_text())
        self.assertEqual(len(manifest), len(expected))
        self.assertEqual(len({item['file'] for item in manifest}), len(expected))
        for item in manifest:
            path = self.root / 'out' / item['file']
            self.assertEqual(path.read_bytes(), expected[item['ref']])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_sigint_reaches_child(self):
        self.put('demo/token')
        process = subprocess.Popen([KAGI, 'run', '--env', 'DEMO=demo/token', '--',
                                    '/bin/sh', '-c', "printf 'READY\\n'; exec /bin/sleep 30"],
                                   env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            # 等到子进程已经运行，避免信号发送在初始化阶段。
            import select
            self.assertTrue(select.select([process.stdout], [], [], 5)[0])
            self.assertEqual(process.stdout.readline(), b'READY\n')
            os.killpg(process.pid, signal.SIGINT)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_long_or_control_character_command_never_executes(self):
        self.put('demo/token')
        for command in ['x' * 150, 'printf hello\n']:
            marker = self.root / 'should-not-exist'
            result = self.call('run', '--env', 'DEMO=demo/token', '--',
                               '/bin/sh', '-c', command + '; touch ' + shlex.quote(str(marker)))
            self.assertEqual(result.returncode, 64)
            self.assertFalse(marker.exists())

    def test_control_character_is_rejected_even_in_a_short_command(self):
        self.put('demo/token')
        result = self.call('run', '--env', 'DEMO=demo/token', '--',
                           '/bin/sh', '-c', 'printf hello\n')
        self.assertEqual(result.returncode, 64)
        self.assertEqual(result.stdout, b'')

    def test_failed_set_audit_redacts_input_even_if_short(self):
        device_path = next(path for path in (self.root / 'vault/keys').glob('mac-*.json'))
        device = json.loads(device_path.read_text())
        device['secretWrap']['ciphertext'] = 'invalid-base64'
        device_path.write_text(json.dumps(device))
        for value in ['FAKE-FAILED-WRITE', 'x']:
            command = ('printf %s ' + shlex.quote(value) + ' | ' + shlex.quote(KAGI)
                       + ' set demo/fail --stdin; result=$?; exit $result')
            result = subprocess.run(['/bin/zsh', '-c', command], env=self.env,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 65)
            record = json.loads((self.root / 'local/log.jsonl').read_text().splitlines()[-1])
            self.assertEqual(record['result'], 'error')
            self.assertIsNotNone(record['fullCommand'])
            self.assertNotIn(value, record['fullCommand'])
            self.assertIn('‹kagi:demo/fail›', record['fullCommand'])

    def test_concurrent_writes_preserve_every_successful_version(self):
        processes = []
        for number in range(8):
            process = subprocess.Popen([KAGI, 'set', 'demo/race', '--stdin'], env=self.env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE)
            process.stdin.write(('FAKE-VERSION-' + str(number)).encode())
            process.stdin.close()
            process.stdin = None
            processes.append(process)
        successes = 0
        for process in processes:
            _, stderr = process.communicate(timeout=15)
            self.assertIn(process.returncode, [0, 65, 75], stderr)
            successes += process.returncode == 0
        self.assertGreater(successes, 0)
        entries = list((self.root / 'vault/entries').iterdir())
        self.assertEqual(len(entries), 1)
        self.assertEqual(len(list(entries[0].glob('*.kagi'))), successes)
        self.assertEqual(self.call('ls').returncode, 0)

    def test_stdout_and_stderr_still_redact_secrets(self):
        self.put('demo/token')
        result = self.call('run', '--env', 'DEMO=demo/token', '--', '/bin/sh', '-c',
                           'printf %s "$DEMO"; printf %s "$DEMO" >&2; exit 23')
        self.assertEqual(result.returncode, 23)
        self.assertIn('‹kagi:demo/token›'.encode(), result.stdout)
        self.assertIn('‹kagi:demo/token›'.encode(), result.stderr)
        self.assertNotIn(b'FAKE-TOKEN-FOR-TEST', result.stdout + result.stderr)

    def test_code_loading_environment_is_not_inherited_by_default(self):
        self.put('demo/token')
        # 只用假值；不设置 DYLD_*，免得影响 kagi 自己的启动。
        self.env['NODE_OPTIONS'] = '--require=/tmp/kagi-fake-hook.js'
        self.env['npm_config_script_shell'] = '/tmp/kagi-fake-shell'
        self.env['KAGI_FAKE_ORDINARY'] = 'kept'
        script = ('test -z "${NODE_OPTIONS+x}" && test -z "${npm_config_script_shell+x}"'
                  ' && test "$KAGI_FAKE_ORDINARY" = kept && test "$DEMO" = FAKE-TOKEN-FOR-TEST')
        result = self.call('run', '--env', 'DEMO=demo/token', '--', '/bin/sh', '-c', script)
        self.assertEqual(result.returncode, 0, result.stderr)
        stderr = result.stderr.decode()
        self.assertIn('NODE_OPTIONS', stderr)
        self.assertIn('npm_config_script_shell', stderr)
        self.assertNotIn('kagi-fake-hook.js', stderr)

    def test_pass_env_keeps_variable_and_shows_value_in_approval(self):
        self.put('demo/token')
        self.env['NODE_OPTIONS'] = '--require=/tmp/kagi-fake-hook.js'
        result = self.call('run', '--env', 'DEMO=demo/token', '--pass-env', 'NODE_OPTIONS', '--',
                           '/bin/sh', '-c', 'test "$NODE_OPTIONS" = --require=/tmp/kagi-fake-hook.js')
        self.assertEqual(result.returncode, 0, result.stderr)
        description = result.stderr.decode().split('模拟授权说明：')[-1]
        self.assertIn('NODE_OPTIONS=--require=/tmp/kagi-fake-hook.js', description)

    def test_doctor_reports_environment_without_prompting_or_vault(self):
        result = self.call('doctor', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        for key in ['initiator', 'sandboxed', 'securitySession', 'secureEnclave',
                    'localAuthentication', 'configured', 'authTimeoutSeconds']:
            self.assertIn(key, report)
        self.assertNotIn('prompt', report)
        self.assertEqual(report['authTimeoutSeconds'], 90)
        self.assertNotIn('模拟授权说明：'.encode(), result.stderr)
        self.env['KAGI_AUTH_TIMEOUT'] = '5'
        self.assertEqual(self.call('doctor').returncode, 64)

    def test_invalid_pass_env_never_executes(self):
        self.put('demo/token')
        marker = self.root / 'should-not-exist'
        for extra in [['--pass-env', 'HOME'], ['--pass-env', 'NODE_OPTIONS', '--env', 'NODE_OPTIONS=demo/token']]:
            with self.subTest(extra=extra):
                result = self.call('run', '--env', 'DEMO=demo/token', *extra, '--',
                                   '/usr/bin/touch', str(marker))
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse(marker.exists())
                self.assertNotIn('模拟授权说明：'.encode(), result.stderr)


if __name__ == '__main__':
    unittest.main()
