# kagi（鍵）

把密钥交给命令，而不是交给看命令的人或 agent。每次取值、写入都要按指纹，指纹框里写明哪几条 key、交给哪条命令、由谁发起。

- 库是一个文件夹，默认放在 Google Drive 的同步文件夹里，里面的文件全部加密。
- 钥匙在这台 Mac 的 Secure Enclave 里，另有一把恢复密钥抄在纸上。没有库口令。
- 只依赖系统框架（CryptoKit、Security、LocalAuthentication、Foundation、AppKit），加密运算全部交给 CryptoKit 和 Secure Enclave。

## 安装

需要 macOS 15 或更新的系统，以及带 Secure Enclave 的 Mac。

```bash
swift build -c release
```

```bash
sudo install -m 0755 .build/release/kagi /usr/local/bin/kagi
```

装进 root 所有的目录后，同一用户下的其他程序就改不了它。

## 用法

```bash
kagi init                                   # 第一次：建库，显示恢复密钥
kagi set resend/api-key --issuer Resend     # 存一条（隐藏输入）
kagi ls                                     # 列出所有引用（不用按指纹）
kagi run --env RESEND_API_KEY=resend/api-key -- node scripts/send.js
kagi run --stdin resend/api-key -- railway variable set RESEND_API_KEY --stdin --skip-deploys
kagi where resend/api-key                   # 一条的详情
kagi log                                    # 使用记录
kagi guide                                  # 给 agent 看的用法说明
kagi recover                                # 换了 Mac：用恢复密钥加入
kagi repair-index                           # 确认同步完成后，重建缺失或过期索引（需指纹）
```

退出码：
- 77：你拒绝了
- 75：屏幕锁着，或确认期间条目已变化
- 66：引用不存在
- 78：还没设置
- 127：找不到命令

成功时，kagi 原样返回子进程的退出码。

`run` 在授权前将命令解析成绝对路径，并在指纹说明中包含完整命令、工作目录、环境变量/标准输入与引用的对应关系。命令最多 120 个显示宽度，整个说明最多 500；超长或含控制字符时直接拒绝，不截断后运行。这是程序的保守限制，不保证系统弹窗在所有屏幕和系统版本上都完整显示，仍需真实设备验收。脚本内容、可执行文件内容和继承的环境变量不在授权绑定范围内。

库写入使用本机进程锁，已存在的版本文件不会被替换。确认期间条目发生变化时返回 75，请核对后重新请求。缺失索引、版本不一致、重复引用或异常版本文件会停止操作。先确认网盘同步完成；仅缺失或过期索引可用 `kagi repair-index` 修复。缺失索引里的签发方和用途无法恢复。重复引用、冲突文件和缺失版本需要人工核对，修复不会自动选择其中一个。

本机锁不能协调不同 Mac。多设备使用时请串行写入，等待同步完成后再切换设备；网盘若静默覆盖了相同版本号的文件，目前仍不能可靠检测。

## 待处理：AUTH-001，真实 agent 调用未显示系统验证框

2026-10-27 真机验收中，同一台 Mac 的普通 Terminal 已通过建库、写入、更新、环境变量/标准输入注入和输出打码；从 Codex 发起真实取值请求时，用户未看到系统验证框，请求等待 120 秒后超时。采样显示进程停在 Secure Enclave 密钥操作触发的 LocalAuthentication 同步调用中，根因尚未确定。

此问题留待单独处理，当前提交没有修复它。fake 验证已覆盖批准、拒绝与锁屏的业务流程，但不代表真实 agent 弹窗可用。后续需对比普通终端与 agent 的启动上下文，修复后重新验证系统弹窗、取消和锁屏；真实取消、锁屏、跨物理 Mac 恢复及发布版真实库操作尚未验收完成。

## 给 agent

把 `kagi guide` 的输出贴进 `~/.claude/CLAUDE.md` 或项目的 `AGENTS.md`。

## 文档

- [威胁模型](docs/威胁模型.md)：防什么、不防什么。
- [库格式](docs/格式.md)：不看源码也能解开库。
- [recover/recover.swift](recover/recover.swift)：kagi 坏了时，用恢复密钥把所有值解成明文文件；每个条目导出到独立的 `<条目 ID>/<引用最后一段>`，`manifest.json` 记录引用与文件的对应关系，避免命名冲突。

## 开发

```bash
swift test
```

```bash
./scripts/check-recover.sh
python3 scripts/check-cli.py
```

日常回归优先使用 fake 验证：`check-cli.py` 在独立临时库中自动切换批准、拒绝和锁屏，检查被拒绝的新建/覆盖不修改库、命令不执行、拒绝日志打码、解锁后独立请求可成功、索引修复和授权说明。它不依赖真实指纹操作，也不锁定电脑屏幕。

少量真机冒烟：先 `swift build`，再在自己的 Terminal 中运行 `python3 scripts/accept-hardware.py --work <独立空目录>`。脚本不启用软件密钥，使用真实 Secure Enclave；仅用调试版的 `KAGI_HOME` 隔离本机状态，所有存储值均为假值。按提示亲自批准、取消、查看弹窗和保存恢复密钥；恢复密钥不会被脚本捕获或写入验收记录。某步失败会停止，并在指定目录写入 `status.json`；人工核对后可用同一目录加 `--resume` 从取消写入场景继续，旧记录会保留。该脚本覆盖普通终端场景，agent、锁屏、另一台物理 Mac 及 release 二进制操作需要分别验收；模拟通过不代表系统弹窗或真机验证通过。

调试版（`swift build` 不加 `-c release`）可以设置这些环境变量：
- `KAGI_DEBUG_SOFTWARE_KEYS=1`：用软件密钥代替 Secure Enclave，不弹指纹框。
- `KAGI_DEBUG_AUTH_DECISION=approve|deny|locked`：仅在启用软件密钥时生效，默认 `approve`。`deny` 模拟取消本次验证；`locked` 同时禁止取值和读取索引。未知取值直接报错，不会默认批准。调试输出显示本次模拟授权说明。
- `KAGI_HOME=<目录>`：换掉本机状态目录。

再配合 `kagi _debug-init --vault <目录>` 建一个假库，就能在没有指纹的情况下跑命令。发布版里没有这些。测试和调试只用明显的假值。
