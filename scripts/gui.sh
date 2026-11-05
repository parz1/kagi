#!/usr/bin/env bash
set -euo pipefail
kagi_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kagi_flutter="${KAGI_FLUTTER:-$(command -v flutter || true)}"
if [[ -z "$kagi_flutter" && -x "$HOME/.cache/kagi-tools/flutter/bin/flutter" ]]; then
  kagi_flutter="$HOME/.cache/kagi-tools/flutter/bin/flutter"
fi
if [[ ! -x "$kagi_flutter" ]]; then
  echo '请安装 Flutter 或通过 KAGI_FLUTTER 指定 flutter 可执行文件。' >&2
  exit 78
fi
cd "$kagi_root/apps/gui"
kagi_action="${1:-demo}"
if [[ $# -gt 0 ]]; then shift; fi
case "$kagi_action" in
  demo) exec "$kagi_flutter" run -d macos --dart-define=KAGI_BACKEND=fake "$@" ;;
  native) exec "$kagi_flutter" run -d macos --dart-define=KAGI_BACKEND=native "$@" ;;
  test) "$kagi_flutter" analyze; exec "$kagi_flutter" test "$@" ;;
  preview) exec "$kagi_flutter" test tool/capture_preview_test.dart "$@" ;;
  *) echo '用法：scripts/gui.sh demo|native|test|preview [Flutter 参数]' >&2; exit 64 ;;
esac
