#!/usr/bin/env python3
"""从当前环境验收真实取值：弹框、取消、超时和锁屏（AUTH-001）。

真实 Secure Enclave、隔离的测试库、假值；不碰真实库，不启用软件密钥。
建库会显示恢复密钥，只能由用户在自己的 Terminal 里做（测试库的恢复密钥不用保存，也不要贴到聊天里）：

  mkdir -p /tmp/kagi-auth001 && KAGI_HOME=/tmp/kagi-auth001/local .build/debug/kagi init --vault /tmp/kagi-auth001/vault
  printf 'FAKE-KAGI-AUTH001-NOT-A-SECRET' | KAGI_HOME=/tmp/kagi-auth001/local .build/debug/kagi set demo/token --stdin

然后分别在 Terminal 和 agent 里运行，结果写到 <work>/accept-<name>.json：

  python3 scripts/accept-agent.py --work /tmp/kagi-auth001 --name <环境名> [--lock | --lock-only]

每一步的操作写在验证框的命令里（「第2步-请点取消」），不用看这个脚本的输出。
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parent.parent
KAGI = REPO / '.build/debug/kagi'
FAKE = b'FAKE-KAGI-AUTH001-NOT-A-SECRET'
REDACTED = '‹kagi:demo/token›'
TIMEOUT_SECONDS = 10
# 超时后最多再等 5 秒（取消后系统调用仍不返回就直接退出），另留一点启动余量。
TIMEOUT_LIMIT = TIMEOUT_SECONDS + 5 + 3
LOCK_WAIT = 60
# 实测锁屏后约 10 秒内系统还接受密钥操作，之后才拒绝：两个时间点都要测。
LOCK_SETTLE = 12
QUICK_LIMIT = 5


def cue(sound):
    subprocess.run(['afplay', f'/System/Library/Sounds/{sound}.aiff'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--work', required=True, type=Path, help='测试库所在目录（含 local/ 和 vault/）')
    parser.add_argument('--name', required=True, help='这次运行的环境名，只用来命名结果文件')
    parser.add_argument('--lock', action='store_true', help='包含锁屏一步：检测到锁屏后才发起请求')
    parser.add_argument('--lock-only', action='store_true', help='只做锁屏这一步')
    args = parser.parse_args()

    work = args.work.resolve()
    local = work / 'local'
    if not KAGI.exists():
        sys.exit('请先运行 swift build。')
    if not (local / 'device.json').exists():
        sys.exit(f'{local} 里还没有测试库。请先在自己的 Terminal 里按脚本开头的说明建库，agent 不能代做。')

    marks = work / 'marks'
    marks.mkdir(mode=0o700, exist_ok=True)
    env = dict(os.environ, KAGI_HOME=str(local), NO_COLOR='1')
    env.pop('KAGI_DEBUG_SOFTWARE_KEYS', None)
    env.pop('KAGI_DEBUG_AUTH_DECISION', None)
    env.pop('KAGI_AUTH_TIMEOUT', None)

    def kagi(*argv, extra_env=None):
        started = time.monotonic()
        result = subprocess.run([str(KAGI), *argv], env={**env, **(extra_env or {})}, cwd=marks,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=130)
        return result, round(time.monotonic() - started, 1)

    doctor, _ = kagi('doctor', '--json')
    snapshot = json.loads(doctor.stdout)
    report = {
        'name': args.name,
        'environment': {key: snapshot.get(key) for key in [
            'version', 'initiator', 'responsibleProcess', 'bootstrapManager', 'sandboxed',
            'sandboxHints', 'secureEnclave', 'localAuthentication', 'securitySession']},
        'steps': [],
    }

    def record(step, passed, result, seconds, **evidence):
        report['steps'].append(dict(step=step, passed=bool(passed), exit_code=result.returncode,
                                    seconds=seconds, **evidence))
        print(('通过：' if passed else '失败：') + f'{step}（退出码 {result.returncode}，{seconds} 秒）', flush=True)

    def wait_for_lock():
        """发起前确认屏幕真的锁着：看人反应多快不可靠，提早发起会弹框，测的就不是锁屏了。"""
        started = time.monotonic()
        while time.monotonic() - started < LOCK_WAIT:
            if json.loads(kagi('doctor', '--json')[0].stdout).get('screenLocked') is True:
                return True
            time.sleep(0.3)
        return False

    def blocked_attempt(step, marker_name, expected, extra_env=None, limit=None):
        """这一步不该运行命令：用 touch 标记，确认子进程没有执行。"""
        marker = marks / marker_name
        marker.unlink(missing_ok=True)
        result, seconds = kagi('run', '--env', 'KAGI_FAKE=demo/token', '--',
                               '/usr/bin/touch', marker_name, extra_env=extra_env)
        stderr = result.stderr.decode(errors='replace')
        passed = (result.returncode == expected[0] and expected[1] in stderr
                  and not marker.exists() and (limit is None or seconds <= limit))
        record(step, passed, result, seconds, command_ran=marker.exists(),
               message=stderr.strip().splitlines()[-3:])
        marker.unlink(missing_ok=True)

    print(f'环境：{args.name}，沙箱：{snapshot.get("sandboxed")}，发起方：{snapshot["initiator"]["label"]}', flush=True)

    if not args.lock_only:
        print('\n第 1 步：框里写着「第1步-请按通过」，请按通过。', flush=True)
        cue('Ping')
        result, seconds = kagi('run', '--env', 'KAGI_FAKE=demo/token', '--',
                               '/bin/sh', '-c', 'printenv KAGI_FAKE', '第1步-请按通过')
        # 子进程拿到了值才能打印出来；值在输出里被打码，不出现明文。
        record('真实取值能弹框并通过', result.returncode == 0
               and REDACTED in result.stdout.decode(errors='replace')
               and FAKE not in result.stdout + result.stderr, result, seconds)

        print('\n第 2 步：框里写着「第2步-请点取消」，请点取消。', flush=True)
        cue('Ping')
        blocked_attempt('点取消返回 77，命令没有运行', '第2步-请点取消',
                        (77, '拒绝' if snapshot['initiator']['isAgent'] else '取消'))

        print(f'\n第 3 步：框里写着「第3步-不要操作」，请不要操作，它会在 {TIMEOUT_SECONDS} 秒后自己消失。', flush=True)
        cue('Ping')
        blocked_attempt('超时返回 75，不卡死，命令没有运行', '第3步-不要操作', (75, '系统验证没有完成'),
                        extra_env={'KAGI_AUTH_TIMEOUT': str(TIMEOUT_SECONDS)}, limit=TIMEOUT_LIMIT)

    if args.lock or args.lock_only:
        print('\n第 4 步：听到低沉的提示音后请锁屏（Control-Command-Q），听到清脆的提示音再解锁。', flush=True)
        cue('Basso')
        if wait_for_lock():
            # 退出码都是 75；限时和说明文字才能区分「立刻知道屏幕锁着」和「白等到超时」。
            quick = dict(extra_env={'KAGI_AUTH_TIMEOUT': '20'}, limit=QUICK_LIMIT)
            blocked_attempt('刚锁屏时立刻返回 75，命令没有运行', '第4步-刚锁屏', (75, '屏幕锁着'), **quick)
            time.sleep(LOCK_SETTLE)
            blocked_attempt('锁屏一会儿后立刻返回 75，命令没有运行', '第4步-锁屏一会儿', (75, '屏幕锁着'), **quick)
            cue('Glass')
        else:
            report['steps'].append(dict(step='锁屏', passed=False, message=f'{LOCK_WAIT} 秒内没有检测到锁屏'))
            print(f'失败：{LOCK_WAIT} 秒内没有检测到锁屏', flush=True)

    report['all_passed'] = all(step['passed'] for step in report['steps'])
    path = work / f'accept-{args.name}.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    path.chmod(0o600)
    print(f'\n{"全部通过" if report["all_passed"] else "有失败"}，记录：{path}', flush=True)
    sys.exit(0 if report['all_passed'] else 1)


if __name__ == '__main__':
    main()
