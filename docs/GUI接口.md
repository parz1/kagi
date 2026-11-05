# GUI 核心接口 v1

Flutter 界面位于 `apps/gui/`，Dart 入口依赖 `KagiClient`，不依赖平台库。`FakeKagiClient` 是内存演示实现；`NativeKagiClient` 通过 macOS MethodChannel 调用 `KagiGUIBridge`，后者直接复用 `KagiCore`。没有子进程 shell 调用、HTTP 服务或 Kagi 账号。

## Dart 合约

模型与接口见 `apps/gui/lib/core/client.dart`。`VaultSnapshot` 包含 `mode`、`status`、库 ID、Space、条目元数据与能力表。条目沿用 CLI 的 `{entry, revision, record}`；`revision` 是不透明的乐观并发令牌，写入、复制、生成验证码必须提交读取到的令牌。

| 方法 | 返回与限制 |
|---|---|
| `snapshot()` | 当前状态；锁定时不返回条目与 Space |
| `unlock()` / `lock()` | 解锁经核心验证；锁定清除 GUI 元数据与临时验证码，不撤销其他进程权限 |
| `create(KeyDraft)` | 普通文本密钥或 TOTP 导入；GUI 单次值上限 64 KiB；不覆盖已有引用 |
| `update(expected, metadata)` | 改标题、Space、标签、备注与归档；保留值、引用和类型；拒绝旧 revision |
| `space(action, id, name)` | 创建、重命名与删除空 Space；默认 Space 不删除 |
| `copySecret(expected)` | 原生验证后直接复制，不把普通密钥明文传回 Flutter；与 CLI 一样只留在本机并标记为隐藏、临时；30 秒后或正常退出时，仅清除仍由本次操作持有的剪贴板 |
| `totp(expected)` | 返回当前临时验证码与失效时间，不返回种子 |
| `synchronize(path, choices)` | 目录同步、冲突摘要、同次提交全部选择；中断安装可恢复 |

`CoreCapabilities` 声明 `manage`、`copySecret`、`totp`、`directorySync`、`passkeyProvider`，缺失字段按不支持处理。当前没有通用 `readSecret`、导出私钥、恢复密钥输入、执行命令或修改任意库路径的 GUI 接口。密钥轮换、GUI 建库/恢复、浏览器与系统 Passkey 提供者留待后续。

## macOS 通道

通道名 `dev.kagi/core.v1`，Dart 调用原生只接受名为 `request` 的方法。macOS 菜单可反向发送 `shortcut` / `search` 聚焦搜索，不提供敏感操作的反向指令。参数为 UTF-8 JSON 字符串：

```json
{"version":1,"method":"update","arguments":{"ref":"demo/key","revision":"opaque-token","metadata":{"title":"Demo","space":"default","tags":["dev"],"notes":null,"archived":false}}}
```

成功：`{"version":1,"result":{...}}`；失败：`{"version":1,"error":{"code":75,"message":"..."}}`。拒绝未知操作、未知顶层或操作字段与不支持的协议版本。请求上限 1 MiB。响应不回显请求、秘密或任意原生错误。错误码沿用核心：64 用法、65 数据、66 不存在、75 锁定/快照过期/暂不能继续、77 拒绝、78 未配置。GUI 对 75 采取保守的清屏并重新解锁流程。

状态：`unconfigured`（本机尚未建库）、`locked`、`ready`、`syncRecovery`（已验证，但需使用原同步目标恢复中断安装）。连接错误单独显示，不自动改用 fake 数据。`mode` 是 `fake`、`native` 或调试宿主的 `software`。

Swift 宿主在串行后台队列中调用核心，结果回主线程；剪贴板操作也在主线程执行。每次敏感操作重新 `Session.unlock`，不缓存库密钥。普通密钥复制发生在原生侧，Flutter 只收到成功状态。TOTP 是唯一返回的秘密派生显示值，按到期时间清除；切换条目、搜索、锁定、失去活跃状态与销毁页面也清除；异步响应带界面代次检查，不能在锁定后重新显示代码。

失去活跃状态先清除验证码；进入后台/隐藏时锁定 GUI。单独的 inactive 状态也可能来自原生系统验证框，因此不会在验证过程中把解锁流程自我锁死。用户手动锁定立即清除界面模型。此锁是 GUI 会话边界，不是整个库的跨进程撤销；已经复制的值仍按剪贴板期限或正常退出清除；应用被强制终止、系统崩溃时无法保证剪贴板清除。

`gui-authorize-*` 日志只表示该次系统授权的结果，不表示后续磁盘操作一定完成。不记录值、种子、验证码、私钥、请求 JSON 或子进程命令。

## fake 与验收边界

Dart fake 是内存演示库，标题、密钥值、通行密钥与验证码都是虚构的。演示验证码固定为 `246810`，用于测试交互和到期清除；算法正确性由 Swift RFC 测试覆盖。演示同步不访问任何目录或云端，可模拟双方冲突并选择；不是实际同步服务。模拟批准、拒绝、锁定不会改变系统认证设置。

macOS DEBUG 宿主另外支持 `KAGI_GUI_TEST_HOME` 和 `KAGI_GUI_TEST_DECISION`，只用于独立软件密钥测试库。发布宿主不编译这些环境入口。端到端测试先检查返回的 mode 必须为 software，才允许验证和写入，避免误操作本机真实库。

当前 macOS 开发宿主关闭 App Sandbox，以访问已有 CLI 的 Application Support 库和独立目录仓库。它不是 Mac App Store 分发配置；商店版需先设计 App Group/库迁移、用户选择目录与 security-scoped bookmark，再启用沙箱。iOS、Android、Windows、Linux、Web 目前提供同一 GUI 和 fake 实现，尚未接入原生安全后端。真实指纹、AUTH-001、系统自动填充与 Passkey 提供者没有因这些 fake 测试而被视为通过。

## 参考

- [Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)
- [Flutter Swift Package Manager 接入](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
