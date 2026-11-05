# Kagi GUI

Flutter 紧凑密钥工作台：172 px 侧栏、42 px 表格行、300 px 详情检查器；手机使用 58 px 条目行与独立详情导航。默认进入清楚标记的内存演示库，不接触真实凭据；macOS 可以切换到现有 Swift 核心。无需 Kagi 账号。

在仓库根目录运行：

```sh
scripts/gui.sh demo             # macOS 演示界面
scripts/gui.sh native           # macOS 现有本机库；敏感操作需系统验证
scripts/gui.sh test             # Dart 分析与交互/客户端测试
python3 scripts/check-gui-native.py  # 原生通道 + Swift 核心；独立 fake 库
scripts/gui.sh preview          # 可选本机渲染检查，PNG 写入 apps/gui/.preview
```

脚本优先使用 PATH 中的 Flutter，或环境变量 `KAGI_FLUTTER` 指定的可执行文件；也识别本次开发使用的 `~/.cache/kagi-tools/flutter/bin/flutter`，不会自动下载 SDK。当前使用 Flutter 3.47.9 / Dart 3.13.7。

普通 Flutter 命令也可直接在本目录运行：

```sh
flutter run -d macos --dart-define=KAGI_BACKEND=fake
flutter run -d macos --dart-define=KAGI_BACKEND=native
flutter build macos --release
flutter test
```

界面支持管理 key、Space、标签、搜索、归档、TOTP 临时显示、同步与冲突选择。Passkey 当前只展示与管理元数据，创建与系统提供者未接入。普通密钥通过原生验证后复制，不返回 Flutter 明文；编辑页目前修改管理信息，值轮换继续使用 CLI。

手机 UI 通过 360/390/768 宽度的导航与溢出测试；这不等于全部手机平台的发布验收。其他平台的原生安全与同步适配尚未实现。macOS 最低 15，复用现有 `KagiCore` 和 `KagiGUIBridge` 本地 Swift Package；开发宿主暂未启用 App Sandbox，尚非商店发布配置。接口、认证和测试边界见 [GUI接口](../../docs/GUI接口.md)。

视觉方案按 Anthropic frontend-design 技能重做，设计 token 与取舍见 [GUI设计](../../docs/GUI设计.md)。支持 Cmd/Ctrl+F 搜索、Cmd/Ctrl+N 添加、Cmd/Ctrl+Shift+L 锁定，以及类型筛选和名称排序。手机放大字号时行高随文本缩放，主要操作保留至少 44 px 点击区域。
