enum Texts {
  static let version = "kagi 0.1.0"

  static let help = """
    kagi：把密钥交给命令，而不交给看命令的人或 agent。每次取值、写入都要按指纹。

    用法：
      kagi init [--vault <路径>]            第一次在这台 Mac 上用：建库，显示恢复密钥
      kagi set <引用> [--stdin] [--raw]     存一条（新建或覆盖，旧值保留为上一版）
               [--issuer <签发方>] [--used-in <用在哪>]
      kagi run --env 变量名=<引用> ... [--stdin <引用>] -- <命令> [参数...]
                                            把值交给命令：放进环境变量或标准输入
      kagi ls                               列出所有引用和元数据（不用按指纹）
      kagi where <引用>                     看一条的详情（不用按指纹）
      kagi log [-n 条数] [--full]           看使用记录
      kagi guide                            给 agent 看的用法说明
      kagi recover [--vault <路径>]         换了 Mac：用恢复密钥加入已有的库

    引用的写法是「签发方/名字」，比如 resend/api-key。
    退出码：77 你拒绝了；75 屏幕锁着；66 引用不存在；78 还没设置；成功时返回子进程的退出码。
    """

  static let guide = """
    ## 密钥（kagi）

    - 不要向用户要密钥的值，也不要设法读出它。
    - 用 `kagi ls` 查有哪些引用，不需要指纹。
    - 要用密钥时，让 kagi 把值交给命令：
        kagi run --env 变量名=引用 -- 命令
        kagi run --stdin 引用 -- 命令
    - 每次都会弹指纹框，由用户批准。
    - 退出码 77：用户拒绝了。停下来问用户，不要换方式重试。
    - 退出码 75：屏幕锁着。等用户回来再试。
    - 退出码 66：引用不存在。先跑 `kagi ls`。
    - 输出里的 ‹kagi:引用› 是打过码的值，不要设法还原。
    """
}
