#!/usr/bin/env python3
"""Real macOS MethodChannel + existing Swift core, fake temporary vault only."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
flutter = os.environ.get('KAGI_FLUTTER') or shutil.which('flutter') or str(Path.home() / '.cache/kagi-tools/flutter/bin/flutter')
subprocess.run(['swift', 'build'], cwd=root, check=True)
with tempfile.TemporaryDirectory(prefix='kagi-gui-native-') as name:
    temporary = Path(name)
    local = temporary / 'local'
    env = dict(os.environ, KAGI_DEBUG_SOFTWARE_KEYS='1', KAGI_DEBUG_AUTH_DECISION='approve', KAGI_HOME=str(local))
    subprocess.run([str(root / '.build/debug/kagi'), '_debug-init', '--vault', str(temporary / 'vault')],
                   env=env, capture_output=True, check=True)
    gui_env = dict(os.environ, KAGI_GUI_TEST_HOME=str(local), KAGI_GUI_TEST_DECISION='approve')
    subprocess.run([flutter, 'test', 'integration_test/core_bridge_test.dart', '-d', 'macos'],
                   cwd=root / 'apps/gui', env=gui_env, check=True)
    log = (local / 'log.jsonl').read_text()
    assert 'FAKE-NATIVE-BRIDGE-SECRET' not in log
    assert 'JBSWY3DPEHPK3PXP' not in log
    print('Native GUI integration and audit secret-exclusion checks passed.')
