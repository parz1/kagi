# kagi（鍵）

把密钥交给命令，而不是交给看命令的人或 agent。每次取值、写入都要按指纹，指纹框里写明哪几条 key、交给哪条命令、由谁发起。

- 不需要 Kagi 账号。库默认保存在本机 `~/Library/Application Support/kagi/vault/`，凭据值与管理信息加密；`--vault` 可指定位置。已有库的位置不会自动迁移。
- 同步使用独立加密快照仓库，可离线使用。当前提供目录联调适配器，iCloud、Google Drive、WebDAV 尚未接入。
- 钥匙在这台 Mac 的 Secure Enclave 里，另有一把恢复密钥抄在纸上。没有库口令。
- 只依赖系统框架（CryptoKit、Security、LocalAuthentication、Foundation、AppKit），加密运算全部交给 CryptoKit 和 Secure Enclave。

## GUI 初版

Flutter 界面已加入 `apps/gui/`：桌面三栏、手机分层导航，默认使用虚构数据的内存演示库。macOS 通过原生 MethodChannel 复用 Swift 核心；其他平台的原生后端待接入。可在界面中明确切换演示库与本机库，不会在本机连接失败时静默退回 fake。

```bash
scripts/gui.sh demo
scripts/gui.sh native
```

运行、测试与当前限制见 [GUI README](apps/gui/README.md)，核心接口与认证边界见 [GUI 接口](docs/GUI接口.md)。GUI 初版不含建库/恢复、值轮换或真实系统 Passkey 提供者；已有真实 agent 认证问题仍单独保留。

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
kagi sync --remote /absolute/path/repository # 同步到独立目录仓库（联调适配器）
kagi recover                                # 换了 Mac：用恢复密钥加入
kagi repair-index                           # 确认同步完成后，重建缺失或过期索引（需指纹）
```

退出码：
- 77：你拒绝了
- 75：屏幕锁着、系统验证超时、确认期间条目变化、同步竞争或有待解决冲突
- 66：引用不存在
- 78：还没设置
- 127：找不到命令

成功时，kagi 原样返回子进程的退出码。

`run` 在授权前将命令解析成绝对路径，并在指纹说明中包含完整命令、工作目录、环境变量/标准输入与引用的对应关系。命令最多 120 个显示宽度，整个说明最多 500；超长或含控制字符时直接拒绝，不截断后运行。这是程序的保守限制，不保证系统弹窗在所有屏幕和系统版本上都完整显示，仍需真实设备验收。脚本内容和可执行文件内容不在授权绑定范围内。

继承环境里能让子进程额外加载代码的变量（如 `NODE_OPTIONS`、`PYTHONPATH`、`BASH_ENV`、`DYLD_*`、`npm_config_*`）默认不交给子进程，kagi 会在 stderr 列出被移除的变量名。确实需要时加 `--pass-env 变量名`，变量名和值会写进授权说明：

```bash
kagi run --env API_KEY=demo/api-key --pass-env NODE_OPTIONS -- node scripts/send.js
```

这只是缩小绕过面；`PATH`、`HOME`、配置文件和其余继承变量仍会影响子进程，见[威胁模型](docs/威胁模型.md)。

库写入使用本机进程锁，已存在的版本文件不会被替换。确认期间条目发生变化时返回 75，请核对后重新请求。缺失索引、版本不一致、重复引用或异常版本文件会停止操作。先确认网盘同步完成；仅缺失或过期索引可用 `kagi repair-index` 修复。缺失索引里的管理字段无法恢复，修复出的条目先归档到默认 Space。重复引用、冲突文件和缺失版本需要人工核对，修复不会自动选择其中一个。

本机锁不能协调不同 Mac。直接把旧式库文件夹交给网盘同步仍须串行写入，网盘静默覆盖同版本文件也可能无法检出。新的 `kagi sync` 通过不可变快照、共同祖先与条件更新处理多设备分歧，具体边界见下文。

## 独立同步层（目录联调阶段）

本地库是可离线使用的完整副本；远端保存不可变的加密快照对象和一个 `HEAD`。无需注册或登录 Kagi。目录适配器只用于本机/共享文件系统联调：文件锁必须被所有访问者共享，**不能放进两台设备各自的网盘镜像目录，就当作跨设备 CAS**。各云服务需另行实现条件更新协议。

```bash
kagi sync --remote /absolute/path/repository --json
# 退出码 75 且 conflicts 非空：本地库未应用，核对后逐项选择
kagi sync --remote /absolute/path/repository --resolve <完整冲突ID>=local --json
# 可重复 --resolve；local/remote 指当前这台设备与当前远端
```

- 按共同祖先做三方合并，不比较设备时间。不同引用的 key、不同 ID 的 Space 自动合并；同一个 key 的值、类型、标题、标签、归档、Space 归属作为整体选择，不自动拼接凭据。同名引用在两端分别创建也会冲突。
- 同一 Space 的分歧需要选择；一端删除空 Space、另一端往其中新增或移动 key，会产生 `space-use:<ID>` 依赖冲突。选择该侧同时选择相关 Space 与 key，避免悬空归属；若与已经明确选定的 key 或其他依赖选择矛盾，拒绝应用，要求统一选择。
- 必须在同次调用提交全部冲突选择，尚有冲突时不会应用已选项。JSON 包含祖先、本机、远端的 key/Space 元数据摘要，不包含值或种子。冲突 ID 绑定祖先与双方内容；过期或不存在的选择拒绝应用。未解决时保留双方加密快照。解决后的合并历史也保留被舍弃分支，不删除远端对象；尚无历史浏览、垃圾回收或存储压缩命令。
- 远端 `HEAD` 必须通过 compare-and-swap 更新。竞争失败返回 75，本地库与同步基线不变，再次运行重新合并。本机已确认祖先不在远端历史中时拒绝同步；首次加入前的整体历史回退无法靠本机基线识别。
- 下载后验证快照路径、库身份、全部索引与历史值的认证加密，再安装。安装有加密写前日志；中断后普通取值和管理操作暂停，再用相同同步目标运行 `sync` 恢复。恢复完成后再次运行可继续检查新远端变化。被替代条目若遗留未完成写入的隐藏密文，会移到本机 `.sync-retired/` 保留，不留在活动条目目录中，也不上传。
- 当前每份本地库只绑定一个同步目标。单快照最多 10000 文件、原始文件总计 32 MiB（安装期间新旧文件短暂共存不重复计入快照限制），传输对象最多 64 MiB；单次祖先检查限制 4096 个修订、256 MiB 传输读取。不自动丢弃历史以绕过限制。

新设备无需复制旧设备私钥，可从仓库仅凭恢复密钥加入（需要自己的 Terminal 和系统验证）：

```bash
kagi recover --remote /absolute/path/repository --vault-id <完整库ID> --vault /new/local/vault
```

目标库目录必须尚不存在。完整库 ID 由普通 `sync` 输出，也能从已有库的 `vault.json` 读取。恢复密钥只通过隐藏终端输入，不接受参数或 agent 输入。公开头仅包含库 ID、校验值和原有恢复密钥封装；快照内容、引用和管理信息仍加密。本轮只用软件设备密钥与 fake 认证验收，尚未证明真实跨物理设备、云端传输或真机认证通过。

## 待处理：AUTH-001，真实 agent 调用未显示系统验证框

2026-10-27 真机验收中，同一台 Mac 的普通 Terminal 已通过建库、写入、更新、环境变量/标准输入注入和输出打码；从 Codex 发起真实取值请求时，用户未看到系统验证框，请求等待 120 秒后超时。采样显示进程停在 Secure Enclave 密钥操作触发的 LocalAuthentication 同步调用中，根因尚未确定。

根因仍未确定，弹窗本身没有修复。目前做了两件事，用来缩小范围并避免卡死：

- **不再无限等待。** CLI 等系统验证最多 90 秒（`KAGI_AUTH_TIMEOUT` 可设为 10–600），超时后取消这次验证并返回 75，说明里附带沙箱、图形会话等线索；取消后系统调用仍不返回时直接退出。GUI 行为不变，仍一直等待。
- **`kagi doctor` 对比启动上下文。** 输出发起方进程链、是否在沙箱里（含 `CODEX_SANDBOX` 等环境变量）、安全会话能否使用图形界面、Secure Enclave 与系统验证是否可用。`--prompt` 另外弹一次只验证设备主人的测试框，不读取任何密钥；`--json` 便于对比。

请在同一台 Mac 上分别运行，并对比两份输出：

```bash
kagi doctor --prompt --json > terminal.json      # 自己的 Terminal
kagi doctor --prompt --json > agent.json         # 让 agent 运行同一条命令
```

若 agent 一侧显示在沙箱里、或测试框超时，而终端一侧正常弹出，问题在 agent 的执行环境（例如 Codex 的 seatbelt 沙箱拦住了系统验证），需要在 agent 设置里允许 kagi 在沙箱外运行；若两侧测试框都能弹出，而真实取值仍不弹，问题在 Secure Enclave 密钥操作本身，需要继续排查。超时与诊断目前只在 fake 和单元测试中覆盖，真机上的弹窗、取消、锁屏和超时仍需验收。

## 管理 key

每条 key 恰好属于一个 Space，可带多个标签。旧条目自动显示在 `default` Space 中，读取旧库不改写文件。Space 是组织方式；初版各 Space 使用同一套库密钥，不提供不同的共享或访问权限。

```bash
kagi space create kotolog --name Kotolog
kagi set resend/api-key --space kotolog --title 'Resend 生产' --tag prod --tag api
kagi ls --space kotolog --tag prod --search Resend
kagi edit resend/api-key --space default --tag personal --notes '用途说明'
kagi edit resend/api-key --clear-tags --clear-notes
kagi tags
kagi archive resend/api-key
kagi ls --archived
kagi restore resend/api-key
kagi space rename kotolog --name 'Kotolog 项目'
kagi space remove kotolog                    # 必须为空，归档项也计算在内
```

引用在全库中唯一且保持稳定；改显示名称、移动 Space、改标签不改变引用或值版本。`edit --tag` 替换整组标签；标签去除首尾空白、转小写、去重并排序，多个筛选标签为同时满足。空闲标签自动消失。`--clear-title`、`--clear-tags`、`--clear-notes`、`--clear-issuer`、`--clear-used-in` 清空对应字段。所有管理写入都要求验证，并使用锁和条目快照检查防止覆盖同机并发修改。

归档保留密文和历史版本；普通列表、标签统计和 `run` 排除归档项。使用 `ls --all`、`ls --archived` 或 `where` 查看，再用 `restore` 恢复。归档不是密钥轮换或加密撤销。删除 Space 不会删除 key；必须先移动其中所有条目。当前不提供永久删除 key。

`ls --json`、`where <引用> --json`、`space ls --json`、`tags --json` 提供未来 GUI 可读取的数据，不包含密钥值。key 的 JSON 结构为 `{entry, record}`，其中 `record.metadata` 包含 `title`、`space`、`tags`、`notes`、`archived`。名称、备注和 Space/标签信息用索引密钥加密，屏幕解锁时查询不需要指纹。

新写入的索引是 `kagi-index/2`，需使用新版 kagi；旧版程序会拒绝它，避免丢失管理字段。索引丢失后，`repair-index` 无法恢复这些字段，会将相关 key 放在默认 Space 并设为归档，请核对补填后再恢复；现存索引的管理字段会保留。

GUI 后续以同时覆盖桌面和手机为目标，Flutter 是当前首选候选；本轮只实现核心管理与 CLI。当前安全后端和执行器仍依赖 macOS，尚未实现 Windows/Linux/iOS/Android 支持。跨端界面不等于跨端安全后端，需要分别适配、验收；AUTH-001 继续单独跟踪。

## 验证器凭据：TOTP 与 Passkey 核心

普通 key、TOTP 和 Passkey 使用同一套 Space、标签和归档能力，JSON 中的 `record.kind` 分别为 `secret`、`totp`、`passkey`。TOTP 种子及 Passkey 私钥存放在加密值区，列表/详情不显示它们，普通 `set` 或 `run --env/--stdin` 不能覆盖或导出这些凭据。

### TOTP

```bash
kagi totp import github/alice --stdin --tag auth < account.otpauth
kagi totp code github/alice --json
kagi run --otp OTP=github/alice -- your-command
kagi run --otp-stdin github/alice -- your-command
```

导入支持 `otpauth://totp` URI 或纯 RFC 4648 Base32（与恢复密钥的 Crockford 编码不同）。支持 SHA1、SHA256、SHA512，6–8 位验证码和自定义周期，默认 SHA1/6 位/30 秒。重复/未知 URI 参数、issuer 冲突和非法编码会报错。种子不通过命令参数传入；不要将真实 URI 直接写在命令行中。

`code` 经授权后显示临时验证码；`--json` 同时返回 `validFrom` 与 `validUntil`（Unix 秒，结束时刻不包含在有效期内）。`run --otp` 只向子进程注入当前验证码，stdout/stderr 出现完整验证码时打码；不会交出种子。验证码可能在子进程运行期间过期，不自动重试。TOTP 与 Passkey 专用操作的日志只记录动作、引用和结果，不写入种子、验证码或私钥。`run` 会给本次注入的值和验证码打码；若把其他原始种子直接写入同一段 shell 脚本，仍可能进入整段命令记录，具体边界见威胁模型。

### Passkey 核心联调（fake）

调试版启用 `KAGI_DEBUG_SOFTWARE_KEYS=1` 后可使用：

```bash
kagi passkey register example/alice --stdin < registration-request.json
kagi passkey assert example/alice --stdin < assertion-request.json
```

注册请求是 kagi 核心协议，而非浏览器的完整 WebAuthn options：

```json
{
  "rpID": "example.test",
  "origin": "https://example.test",
  "challenge": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  "userHandle": "ZmFrZS11c2Vy",
  "userName": "alice"
}
```

示例 challenge 只用于测试；真实流程的 challenge 与单次使用检查应由 RP 提供。认证请求只包含 `rpID`、`origin`、`challenge`。所有二进制请求/响应字段使用无填充 base64url；未知字段会拒绝，不会默默忽略 excludeCredentials、算法协商、扩展等尚未支持的要求。只接受规范 HTTPS origin 与 RP ID 完全匹配（不接受父域/子域推导），localhost 测试可用 HTTP。

核心实现 ES256/P-256、COSE 公钥、`none` attestation、注册 authenticatorData 和认证断言。计数器始终为零，不提供克隆检测；凭据声明允许备份（BE=1），尚未确认外部备份状态（BS=0）。UP/UV 为 fake 流程中模拟的验证结果，不能作为真实生物识别已通过的证明。认证响应不包含私钥；Passkey 引用不允许覆盖注册。

此阶段没有浏览器扩展、系统 Credential Provider、CTAP 传输、来源可信通道或 GUI。CLI 仅开放 fake 核心联调，发布版拒绝这些联调命令。算法/签名测试通过不等于真实网站注册登录通过，后续提供者需要绑定真实来源、用户验证和平台备份状态。

TOTP 与 Passkey 值使用 `kagi-entry/2`，索引用 `kagi-index/3`；旧客户端会拒绝，防止种子/私钥被旧程序误当作普通值。新客户端继续读取普通旧值与索引。`recover` 保留类型与凭据；独立恢复脚本会导出包含种子/私钥的内部 JSON，`manifest.json` 标明 `kind`，仅在人工恢复时使用。

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
python3 scripts/check-authenticators.py
python3 scripts/check-sync.py
```

日常回归优先使用 fake 验证：`check-cli.py` 在独立临时库中自动切换批准、拒绝和锁屏，检查被拒绝的新建/覆盖不修改库、命令不执行、拒绝日志打码、解锁后独立请求可成功、索引修复和授权说明。它不依赖真实指纹操作，也不锁定电脑屏幕。验证器回归另用 RFC 6238/4226 向量、Python 标准库 HMAC、独立 CBOR 解码及已安装的 OpenSSL 验签；运行时不增加第三方 Swift 依赖。

少量真机冒烟：先 `swift build`，再在自己的 Terminal 中运行 `python3 scripts/accept-hardware.py --work <独立空目录>`。脚本不启用软件密钥，使用真实 Secure Enclave；仅用调试版的 `KAGI_HOME` 隔离本机状态，所有存储值均为假值。按提示亲自批准、取消、查看弹窗和保存恢复密钥；恢复密钥不会被脚本捕获或写入验收记录。某步失败会停止，并在指定目录写入 `status.json`；人工核对后可用同一目录加 `--resume` 从取消写入场景继续，旧记录会保留。该脚本覆盖普通终端场景，agent、锁屏、另一台物理 Mac 及 release 二进制操作需要分别验收；模拟通过不代表系统弹窗或真机验证通过。

调试版（`swift build` 不加 `-c release`）可以设置这些环境变量：
- `KAGI_DEBUG_SOFTWARE_KEYS=1`：用软件密钥代替 Secure Enclave，不弹指纹框。
- `KAGI_DEBUG_AUTH_DECISION=approve|deny|locked`：仅在启用软件密钥时生效，默认 `approve`。`deny` 模拟取消本次验证；`locked` 同时禁止取值和读取索引。未知取值直接报错，不会默认批准。调试输出显示本次模拟授权说明。
- `KAGI_HOME=<目录>`：换掉本机状态目录。

再配合 `kagi _debug-init --vault <目录>` 建一个假库，就能在没有指纹的情况下跑命令。发布版里没有这些。测试和调试只用明显的假值。
