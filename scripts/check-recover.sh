#!/bin/zsh
# 用调试版 kagi 建一个只有假值的库，再用独立的 recover.swift 解开，核对两边对得上。
set -euo pipefail
cd "${0:A:h}/.."
swift build -q
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export KAGI_DEBUG_SOFTWARE_KEYS=1 KAGI_HOME="$tmp/local" NO_COLOR=1
kagi=.build/debug/kagi
recovery=$($kagi _debug-init --vault "$tmp/vault" 2>/dev/null | sed -E 's/.*恢复密钥（调试库，假的）：//')
printf 'FAKE-VALUE-0001-not-a-secret' > "$tmp/one"
printf -- '-----BEGIN FAKE KEY-----\nFAKE\n-----END FAKE KEY-----\n' > "$tmp/two"
$kagi set demo/fake-token --stdin < "$tmp/one" 2>/dev/null
$kagi set demo/fake-key.p8 --stdin --raw < "$tmp/two" 2>/dev/null
printf 'FAKE-VALUE-0002-not-a-secret' > "$tmp/one"
$kagi set demo/fake-token --stdin < "$tmp/one" 2>/dev/null
print -r -- "$recovery" | swift recover/recover.swift --vault "$tmp/vault" --out "$tmp/out" > /dev/null
cmp -s "$tmp/one" "$tmp/out/demo/fake-token.txt" || { print "最新版本对不上"; exit 1 }
cmp -s "$tmp/two" "$tmp/out/demo/fake-key.p8" || { print "多行的值对不上"; exit 1 }
[[ $(stat -f %Lp "$tmp/out/demo/fake-token.txt") == 600 ]] || { print "输出文件权限不是 0600"; exit 1 }
print "recover.swift 和 kagi 对得上。"
