# kagi（鍵）

把密钥交给命令，而不是交给看命令的人或 agent。每次取值、写入都要按指纹，指纹框里写明哪几条 key、交给哪条命令、由谁发起。

- **不需要账号。** 库默认在 `~/Library/Application Support/kagi/vault/`，值和管理信息都加密；`--vault` 可指定位置。
- **没有库口令。** 钥匙在这台 Mac 的 Secure Enclave 里，另有一把恢复密钥抄在纸上。
- **离线可用。** 多设备通过独立的加密快照仓库同步（目前只有目录适配器）。
- **只用系统框架。** 加密运算全部交给 CryptoKit 和 Secure Enclave，不引入第三方依赖。

> [!WARNING]
> 早期版本。agent 的沙箱会拦住系统验证，kagi 这时会报错退出，需要在 agent 的设置里允许它在沙箱外运行（[AUTH-001](docs/已知问题.md)）。验证框没有出现时，可用 `kagi doctor --prompt` 排查。

## 安装

需要 macOS 15 或更新的系统，以及带 Secure Enclave 的 Mac。

```bash
swift build -c release
```

```bash
sudo install -m 0755 .build/release/kagi /usr/local/bin/kagi
```

装进 root 所有的目录后，同一用户下的其他程序就改不了它。

## 快速上手

```bash
kagi init                                   # 第一次：建库，显示恢复密钥
kagi set resend/api-key --issuer Resend     # 存一条（隐藏输入）
kagi ls                                     # 列出所有引用（不用按指纹）
kagi run --env RESEND_API_KEY=resend/api-key -- node scripts/send.js
kagi run --stdin resend/api-key -- railway variable set RESEND_API_KEY --stdin --skip-deploys
kagi where resend/api-key                   # 一条的详情
kagi log                                    # 使用记录
kagi doctor --prompt                        # 验证框不出现时排查环境
kagi recover                                # 换了 Mac：用恢复密钥加入
```

`run` 只把值交给它启动的子进程，输出里出现的值会被换成 `‹kagi:引用›`；`NODE_OPTIONS` 等能加载额外代码的继承变量默认不交出去。全部命令见 `kagi help`，细节见[使用](docs/使用.md)。

**退出码：** 77 你拒绝了；75 屏幕锁着、验证超时、被沙箱拦住、条目已变化或同步冲突；66 引用不存在；78 还没设置；127 找不到命令。成功时原样返回子进程的退出码。

## 给 agent

把 `kagi guide` 的输出贴进 `~/.claude/CLAUDE.md` 或项目的 `AGENTS.md`。

## GUI

`apps/gui/` 是 Flutter 界面，桌面三栏、手机分层导航，浅色/深色跟随系统。默认打开虚构数据的演示库；macOS 可明确切换到本机库，复用 Swift 核心，本机连接失败时不会静默退回演示库。

```bash
scripts/gui.sh demo
```

见 [GUI README](apps/gui/README.md)、[GUI 设计](docs/GUI设计.md)与 [GUI 接口](docs/GUI接口.md)。GUI 还不能建库、恢复或轮换值。

## 文档

| 文档 | 内容 |
| --- | --- |
| [使用](docs/使用.md) | `run` 的授权说明与环境变量、Space/标签/归档、JSON 输出、库写入与修复、恢复 |
| [同步](docs/同步.md) | 加密快照仓库、三方合并与冲突选择、从仓库加入新设备 |
| [验证器](docs/验证器.md) | TOTP 导入与注入、Passkey 核心联调（fake） |
| [威胁模型](docs/威胁模型.md) | 防什么、不防什么 |
| [库格式](docs/格式.md) | 不看源码也能解开库；配合 [recover/recover.swift](recover/recover.swift) 导出明文 |
| [已知问题](docs/已知问题.md) | AUTH-001 与尚未验收的场景 |
| [开发](docs/开发.md) | 测试脚本、真机冒烟、调试版环境变量 |
