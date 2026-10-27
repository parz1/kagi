#!/usr/bin/env python3
"""在用户自己的 Terminal 里验收真实 Secure Enclave；不记录恢复密钥。

swift build 后运行：python3 scripts/accept-hardware.py --work <独立空目录>
只使用假值。KAGI_HOME 用于隔离本机状态；不启用软件密钥。
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
KAGI = REPO / '.build/debug/kagi'
FAKE1 = b'FAKE-KAGI-HARDWARE-V1-NOT-A-SECRET'
FAKE2 = b'FAKE-KAGI-HARDWARE-V2-NOT-A-SECRET'
MULTILINE = b'-----BEGIN FAKE KEY-----\nFAKE-HARDWARE-ONLY\n-----END FAKE KEY-----\n'

RECEIVER = '''#!/usr/bin/env python3
import os, pathlib, sys, time
mode = sys.argv[1]
expected = {
    'v1': b'FAKE-KAGI-HARDWARE-V1-NOT-A-SECRET',
    'v2': b'FAKE-KAGI-HARDWARE-V2-NOT-A-SECRET',
    'stdin': b'-----BEGIN FAKE KEY-----\\nFAKE-HARDWARE-ONLY\\n-----END FAKE KEY-----\\n',
}
if mode == 'marker':
    pathlib.Path('should-not-run').write_text('executed')
    sys.exit(0)
if mode == 'sleep':
    print('子进程已开始运行，现在请按 Ctrl-C。', flush=True)
    time.sleep(120)
    sys.exit(1)
value = sys.stdin.buffer.read() if mode == 'stdin' else os.environ['KAGI_FAKE'].encode()
if value != expected[mode]:
    print('假值字节不匹配', file=sys.stderr)
    sys.exit(1)
sys.stdout.buffer.write(value)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(value)
sys.stderr.buffer.flush()
sys.exit(23)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--resume', action='store_true', help='保留前次记录，从取消写入场景继续')
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    status_path = work / 'status.json'
    previous = None
    if args.resume:
        if not status_path.exists() or not (work / 'local/device.json').exists():
            sys.exit('没有可继续的真机测试库。')
        previous = json.loads(status_path.read_text())
        if previous.get('stage') != 'failed':
            sys.exit('仅允许从失败后的人工复核继续。')
    elif status_path.exists():
        sys.exit('此目录已有验收记录，请使用新目录，避免覆盖测试状态。')
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        sys.exit('请从自己的 Terminal 运行，不能在 agent 输出捕获中运行。')
    if not KAGI.exists():
        sys.exit('请先运行 swift build。')
    scratch = Path(tempfile.mkdtemp(prefix='kagi-hw-'))
    # 接收器路径保持短小，确保被授权的完整命令不超过展示限制。
    receiver = scratch / 'receiver.py'
    receiver.write_text(RECEIVER)
    receiver.chmod(0o700)
    env = dict(os.environ, KAGI_HOME=str(work / 'local'), NO_COLOR='1')
    env.pop('KAGI_DEBUG_SOFTWARE_KEYS', None)
    env.pop('KAGI_DEBUG_AUTH_DECISION', None)
    report = {'stage': 'starting', 'backend': 'SecureEnclaveBackend',
              'configuration': 'debug (KAGI_HOME isolation only)',
              'work': str(work), 'receiver': str(receiver), 'checks': []}

    def save(stage):
        report['stage'] = stage
        temporary = status_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        temporary.chmod(0o600)
        temporary.replace(status_path)

    def check(name, passed, **evidence):
        report['checks'].append(dict(name=name, passed=bool(passed), **evidence))
        save('running' if passed else 'failed')
        print(('通过：' if passed else '失败：') + name, flush=True)
        if not passed:
            raise RuntimeError(name)

    def observe(name):
        answer = input(name + ' [y/N] ').strip().lower()
        check(name, answer == 'y', evidence='用户在真实系统界面确认')

    def call(*argv, data=None, custom_env=None, timeout=180):
        # 只捕获 set/run/ls 等假值流程；init 和 recover 必须继承用户终端。
        result = subprocess.run([str(KAGI), *argv], env=custom_env or env,
                                cwd=scratch, input=data, capture_output=True, timeout=timeout)
        if result.returncode not in (0, 23, 65, 75, 77):
            print(result.stderr.decode(errors='replace'))
        return result

    def run_value(mode, custom_env=None):
        args = ['run']
        args += ['--stdin', 'demo/multiline'] if mode == 'stdin' else ['--env', 'KAGI_FAKE=demo/token']
        result = call(*args, '--', str(receiver), mode, custom_env=custom_env)
        expected = MULTILINE if mode == 'stdin' else FAKE1 if mode == 'v1' else FAKE2
        check('注入及双输出打码：' + mode,
              result.returncode == 23 and expected not in result.stdout + result.stderr
              and '‹kagi:demo/'.encode() in result.stdout
              and '‹kagi:demo/'.encode() in result.stderr,
              exit_code=result.returncode)

    if previous is not None:
        archive = work / ('status-before-resume-' + str(time.time_ns()) + '.json')
        archive.write_text(json.dumps(previous, ensure_ascii=False, indent=2))
        archive.chmod(0o600)
        report['previous_attempt'] = archive.name
    save('starting')
    print('\n这是 kagi 真机验收：隔离库、假值、真实 Secure Enclave。')
    print('请只按当前步骤批准或取消。恢复密钥仅在这个终端显示，请自己保存，不要贴到聊天。')
    print('本轮不会改动你现有的 kagi 库，也不会锁定屏幕。锁屏场景另行安排。\n')
    try:
        if not args.resume:
            save('init-awaiting-user')
            print('第一步：建库。请批准指纹验证，保存恢复密钥，再按 kagi 的提示确认。', flush=True)
            code = subprocess.run([str(KAGI), 'init', '--vault', str(work / 'vault')],
                                  env=env, cwd=scratch).returncode
            check('真实设备建库', code == 0, exit_code=code)

            print('\n第二步：存入假 API key，请批准。', flush=True)
            result = call('set', 'demo/token', '--stdin', '--issuer', 'Hardware acceptance', data=FAKE1)
            check('存入假值', result.returncode == 0, exit_code=result.returncode)
            observe('刚才写入确实要求了新的系统验证')
            result = call('ls')
            detail = call('where', 'demo/token')
            check('列表和详情不显示值', result.returncode == detail.returncode == 0
                  and FAKE1 not in result.stdout + detail.stdout)
            observe('刚才 ls 和 where 没有弹出验证框')

            print('\n第三步：环境变量注入。请批准，并检查授权说明。', flush=True)
            run_value('v1')
            observe('弹窗能看清完整程序路径、参数、目录和 KAGI_FAKE=demo/token，且确实要求验证')

            print('\n第四步：更新为第二版假值，请批准。', flush=True)
            result = call('set', 'demo/token', '--stdin', data=FAKE2)
            check('更新假值', result.returncode == 0)
            observe('弹窗明确表示覆盖并保留旧版本，且确实要求验证')
            print('再次验证子进程拿到第二版，请批准。', flush=True)
            run_value('v2')

            print('\n第五步：存入多行假私钥，再通过标准输入使用；请分别批准两次。', flush=True)
            result = call('set', 'demo/multiline', '--stdin', '--raw', data=MULTILINE)
            check('多行假值写入', result.returncode == 0)
            run_value('stdin')

        print('\n第六步：拒绝写入。接下来的验证框请点「取消」。', flush=True)
        cancelled_ref = 'demo/cancelled-' + str(time.time_ns())
        result = call('set', cancelled_ref, '--stdin', data=b'FAKE-CANCELLED-WRITE')
        listing = call('ls')
        check('取消写入返回 77 且未创建条目', result.returncode == 77
              and listing.returncode == 0 and cancelled_ref.encode() not in listing.stdout,
              exit_code=result.returncode)

        print('\n第七步：拒绝命令。接下来的验证框请点「取消」。', flush=True)
        result = call('run', '--env', 'KAGI_FAKE=demo/token', '--', str(receiver), 'marker')
        check('取消命令返回 77 且没有执行', result.returncode == 77
              and not (scratch / 'should-not-run').exists(), exit_code=result.returncode)

        print('\n第八步：中断命令。先批准，看到子进程提示后按 Ctrl-C。', flush=True)
        old_handler = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            code = subprocess.run([str(KAGI), 'run', '--env', 'KAGI_FAKE=demo/token',
                                   '--', str(receiver), 'sleep'], env=env, cwd=scratch).returncode
        finally:
            signal.signal(signal.SIGINT, old_handler)
        check('真实终端 Ctrl-C 返回 130', code == 130, exit_code=code)

        print('\n第九步：模拟测试库索引缺失，先检测，再重建。请批准重建。', flush=True)
        index_file = next((work / 'vault/index').glob('*.kagi'))
        backup = work / 'removed-index.kagi'
        shutil.move(str(index_file), backup)
        result = call('ls')
        check('索引缺失被检测', result.returncode == 65)
        result = call('repair-index')
        check('真实验证后重建索引', result.returncode == 0)
        print('读取重建后的第二版假值，请批准。', flush=True)
        run_value('v2')

        print('\n第十步：用恢复密钥加入另一套隔离本机状态。请亲自输入恢复密钥并批准。', flush=True)
        recovered_env = dict(env, KAGI_HOME=str(work / 'recovered-local'))
        code = subprocess.run([str(KAGI), 'recover', '--vault', str(work / 'vault')],
                              env=recovered_env, cwd=scratch).returncode
        check('同机新设备状态恢复', code == 0, exit_code=code)
        print('验证恢复后仍可取出正确值，请批准。', flush=True)
        run_value('v2', custom_env=recovered_env)

        print('\n第十一步：独立脚本恢复。请再次输入恢复密钥，不会经过 agent。', flush=True)
        code = subprocess.run(['swift', str(REPO / 'recover/recover.swift'),
                               '--vault', str(work / 'vault'), '--out', str(work / 'export')],
                              cwd=scratch).returncode
        check('独立恢复脚本执行', code == 0, exit_code=code)
        manifest = json.loads((work / 'export/manifest.json').read_text())
        values = {item['ref']: (work / 'export' / item['file']).read_bytes() for item in manifest}
        check('独立恢复字节一致', values.get('demo/token') == FAKE2 and values.get('demo/multiline') == MULTILINE)
        check('假值未写入使用日志', all(value not in (work / 'local/log.jsonl').read_bytes()
              for value in [FAKE1, FAKE2, MULTILINE, b'FAKE-CANCELLED-WRITE']))
        report['untested'] = ['锁屏', '不同物理 Mac 恢复及 Google Drive 同步', 'release 二进制真实库操作']
        save('native-complete-awaiting-agent')
        print('\n普通终端验收通过。请回聊天告诉我「普通阶段完成」，接下来由 agent 发起请求。')
        print('记录位置：' + str(status_path))
    except (Exception, KeyboardInterrupt) as error:
        report['failure_type'] = type(error).__name__
        save('failed')
        print('\n验收停止；不会自动重复被拒绝的操作。记录位置：' + str(status_path))
        print('请回聊天告知停在哪一步；不要贴恢复密钥。')
        sys.exit(1)


if __name__ == '__main__':
    main()
