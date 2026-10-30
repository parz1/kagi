#!/usr/bin/env python3
"""Independent-process sync regression. Temporary directories and fake device keys only."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('kagi_cli_fixture', Path(__file__).with_name('check-cli.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class SyncCLITests(fixture.CLIFixture):
    def sync(self, choices=(), expected=0):
        args = ['sync', '--remote', str(self.root / 'remote'), '--json']
        for choice in choices:
            args += ['--resolve', choice]
        result = self.call(*args)
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout)

    def clone(self):
        self.home_a = self.env['KAGI_HOME']
        shutil.copytree(self.root / 'vault', self.root / 'vault-b')
        shutil.copytree(self.root / 'local', self.root / 'local-b')
        state_path = self.root / 'local-b/device.json'
        state = json.loads(state_path.read_text())
        state['vaultPath'] = str(self.root / 'vault-b')
        state_path.write_text(json.dumps(state))
        self.home_b = str(self.root / 'local-b')

    def side(self, side):
        self.env['KAGI_HOME'] = self.home_a if side == 'a' else self.home_b

    def test_default_vault_is_local_and_needs_no_cloud_account(self):
        self.env['KAGI_HOME'] = str(self.root / 'fresh-local')
        result = self.call('_debug-init')
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.root / 'fresh-local/device.json').read_text())
        self.assertEqual(state['vaultPath'], str(self.root / 'fresh-local/vault'))
        self.assertTrue((self.root / 'fresh-local/vault/vault.json').is_file())

    def test_distinct_process_replicas_merge_and_converge(self):
        first = self.sync()
        self.clone()
        self.put('a/token', b'FAKE-A')
        self.sync()
        self.side('b')
        self.put('b/token', b'FAKE-B')
        second = self.sync()
        self.assertFalse(second['conflicts'])
        self.assertNotEqual(first['revision'], second['revision'])
        self.side('a')
        self.sync()
        refs = {item['record']['ref'] for item in json.loads(self.call('ls', '--json').stdout)}
        self.assertEqual(refs, {'a/token', 'b/token'})
        self.assertEqual(self.sync()['revision'], second['revision'])

    def test_conflict_exit_and_explicit_remote_choice(self):
        self.put('api/key', b'FAKE-BASE')
        self.sync()
        self.clone()
        self.put('api/key', b'FAKE-A')
        self.sync()
        self.side('b')
        self.put('api/key', b'FAKE-B')
        conflict = self.sync(expected=75)
        self.assertEqual([item['item'] for item in conflict['conflicts']], ['key:api/key'])
        decision = conflict['conflicts'][0]['id'] + '=remote'
        self.assertFalse(self.sync([decision])['conflicts'])
        result = self.call('run', '--env', 'VALUE=api/key', '--', '/bin/sh', '-c', 'test "$VALUE" = FAKE-A')
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (self.root / 'remote').rglob('*'):
            if path.is_file():
                self.assertNotIn(b'FAKE-A', path.read_bytes())
        log = (self.root / 'local-b/log.jsonl').read_text()
        self.assertNotIn('FAKE-A', log)
        self.assertNotIn('FAKE-B', log)

    def test_denied_and_locked_sync_leave_remote_and_vault_unchanged(self):
        self.put('api/key')
        before = self.vault_snapshot()
        for decision, code in [('deny', 77), ('locked', 75)]:
            self.env['KAGI_DEBUG_AUTH_DECISION'] = decision
            result = self.call('sync', '--remote', str(self.root / 'remote'), '--json')
            self.assertEqual(result.returncode, code, result.stderr)
            self.assertFalse(result.stdout)
            self.assertFalse((self.root / 'remote').exists())
            self.assertEqual(self.vault_snapshot(), before)

    def test_bad_args_and_nested_remote_fail_before_side_effects(self):
        for args in [
            ['sync', '--remote', str(self.root / 'vault/nested')],
            ['sync', '--remote', str(self.root)],
            ['sync', '--remote', 'relative'],
            ['sync', '--remote', str(self.root / 'remote'), '--resolve', 'bad=invalid'],
            ['recover', '--remote', str(self.root / 'remote')],
            ['recover', '--remote', str(self.root / 'remote'), '--vault-id', '../bad'],
        ]:
            result = self.call(*args)
            self.assertEqual(result.returncode, 64, result.stderr)
            self.assertFalse((self.root / 'remote').exists())

    def test_corrupt_head_fails_without_partial_download(self):
        self.sync()
        remote = self.root / 'remote'
        head = next(remote.glob('*/HEAD'))
        head.write_text('../invalid')
        before = self.vault_snapshot()
        result = self.call('sync', '--remote', str(remote), '--json')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(self.vault_snapshot(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
