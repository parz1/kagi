enum Texts {
  static let version = "kagi 0.1.0"

  static let help = """
    kagi：把密钥交给命令，而不交给看命令的人或 agent。每次取值、写入都要按指纹。

    用法：
      kagi init [--vault <路径>]            第一次在这台 Mac 上用：建库，显示恢复密钥
      kagi set <引用> [--stdin] [--raw]     存一条（新建或覆盖，旧值保留为上一版）
               [--issuer <签发方>] [--used-in <用在哪>] [--space <ID>] [--title <名称>] [--tag <标签>]...
      kagi space ls [--json]               查看 Space；create <ID> [--name <名称>] 新建
      kagi space rename <ID> --name <名称>  修改 Space 名称；remove <ID> 删除空 Space
      kagi edit <引用> [--space <ID>] [--title <名称>] [--tag <标签>]... [--notes <备注>]
               [--issuer <签发方>] [--used-in <用在哪>]
               [--clear-title] [--clear-tags] [--clear-notes] [--clear-issuer] [--clear-used-in]
                                            修改管理信息；--tag 替换整组标签，不改变值或引用
      kagi archive <引用> / restore <引用>    归档或恢复（保留值和历史版本）
      kagi tags [--all] [--json]            查看标签及使用数量
      kagi totp import <引用> --stdin [--space <ID>] [--tag <标签>]...
                                            导入 otpauth://totp URI 或 RFC 4648 Base32 种子
      kagi totp code <引用> [--json]        授权生成当前验证码及有效期，不显示种子
      kagi passkey register|assert <引用> --stdin
                                            fake 调试核心联调；请求 JSON，尚未接入系统提供者
      kagi run [--env 变量名=<引用>]... [--stdin <引用>]
               [--otp 变量名=<TOTP 引用>]... [--otp-stdin <TOTP 引用>] -- <命令> [参数...]
                                            交出普通值或临时验证码，不交出验证器种子/私钥
      kagi ls [--space <ID>] [--tag <标签>]... [--search <关键词>] [--all|--archived] [--json]
                                            筛选 key（多个标签为同时满足；默认隐藏归档项）
      kagi where <引用> [--json]            看一条的详情（包含归档项，不显示值）
      kagi log [-n 条数] [--full]           看使用记录
      kagi guide                            给 agent 看的用法说明
      kagi sync --remote <绝对路径>         同步加密快照；目录适配器用于联调
      kagi repair-index                     确认同步完成后，从条目重建缺失或过期索引（需指纹）
      kagi recover [--vault <路径>]         换了 Mac：用恢复密钥加入已有的库
      kagi recover --remote <绝对路径> --vault-id <库ID> --vault <新目录>
                                            用恢复密钥从同步仓库加入

    引用的写法是「签发方/名字」，比如 resend/api-key。
    退出码：77 你拒绝了；75 暂时无法继续（锁屏或条目已变化）；66 引用不存在；78 还没设置；成功时返回子进程的退出码。
    """

  static let guide = """
    ## 密钥（kagi）

    - 不要向用户要密钥的值，也不要设法读出它。
    - 用 `kagi ls` 查有哪些引用，不需要指纹；可用 --space、--tag、--search 筛选。
    - `kagi ls --json`、`kagi where <引用> --json` 输出管理数据，均不包含值。
    - key 引用全库唯一；移动 Space、改名称不会改引用。归档项须先经批准恢复才能使用。
    - 要用密钥时，让 kagi 把值交给命令：
        kagi run --env 变量名=引用 -- 命令
        kagi run --stdin 引用 -- 命令
    - TOTP 使用 `kagi run --otp 变量名=引用 -- 命令` 或 `--otp-stdin 引用`；只注入临时验证码。
    - 普通 --env/--stdin 不接受 TOTP 种子或 Passkey 私钥；不要设法将其当作普通 key 导出。
    - Passkey CLI 目前仅用于 fake 核心联调，不能作为真实网站的凭据提供者。
    - 真实后端按次要求系统验证；fake 测试不弹真实指纹框。
    - 退出码 77：用户拒绝了。停下来问用户，不要换方式重试。
    - 退出码 75：按错误提示处理。锁屏时等用户回来；条目已变化时先核对，不要盲目重试。
    - 退出码 66：引用不存在。先跑 `kagi ls`。
    - 输出里的 ‹kagi:引用› 是打过码的值，不要设法还原。
    """
}
