#!/bin/zsh
# 用调试版 kagi 建一个只有假值的库，再用独立的 recover.swift 解开，核对两边对得上。
set -euo pipefail
cd "${0:A:h}/.."
swift build -q
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export KAGI_DEBUG_SOFTWARE_KEYS=1 KAGI_DEBUG_AUTH_DECISION=approve KAGI_HOME="$tmp/local" NO_COLOR=1
kagi=.build/debug/kagi
recovery=$($kagi _debug-init --vault "$tmp/vault" 2>/dev/null | sed -E 's/.*恢复密钥（调试库，假的）：//')
printf 'FAKE-VALUE-0001-not-a-secret' > "$tmp/one"
printf -- '-----BEGIN FAKE KEY-----\nFAKE\n-----END FAKE KEY-----\n' > "$tmp/two"
$kagi set demo/fake-token --stdin < "$tmp/one" 2>/dev/null
$kagi set demo/fake-key.p8 --stdin --raw < "$tmp/two" 2>/dev/null
printf 'FAKE-VALUE-0002-not-a-secret' > "$tmp/one"
$kagi set demo/fake-token --stdin < "$tmp/one" 2>/dev/null
print -r -- "$recovery" | swift recover/recover.swift --vault "$tmp/vault" --out "$tmp/out" > /dev/null
python3 - "$tmp" <<'CHECK'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'out/manifest.json').read_text())
paths = {item['ref']: root / 'out' / item['file'] for item in manifest}
assert paths['demo/fake-token'].read_bytes() == (root / 'one').read_bytes()
assert paths['demo/fake-key.p8'].read_bytes() == (root / 'two').read_bytes()
assert all(path.stat().st_mode & 0o777 == 0o600 for path in paths.values())
CHECK
print "recover.swift 和 kagi 对得上。"
