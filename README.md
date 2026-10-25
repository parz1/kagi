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
```

退出码：
- 77：你拒绝了
- 75：屏幕锁着
- 66：引用不存在
- 78：还没设置
- 127：找不到命令

成功时，kagi 原样返回子进程的退出码。

## 给 agent

把 `kagi guide` 的输出贴进 `~/.claude/CLAUDE.md` 或项目的 `AGENTS.md`。

## 文档

- [威胁模型](docs/威胁模型.md)：防什么、不防什么。
- [库格式](docs/格式.md)：不看源码也能解开库。
- [recover/recover.swift](recover/recover.swift)：kagi 坏了时，用恢复密钥把所有值解成明文文件。

## 开发

```bash
swift test
```

```bash
./scripts/check-recover.sh
```

调试版（`swift build` 不加 `-c release`）可以设置两个环境变量：
- `KAGI_DEBUG_SOFTWARE_KEYS=1`：用软件密钥代替 Secure Enclave，不弹指纹框。
- `KAGI_HOME=<目录>`：换掉本机状态目录。

再配合 `kagi _debug-init --vault <目录>` 建一个假库，就能在没有指纹的情况下跑命令。发布版里没有这些。测试和调试只用明显的假值。
