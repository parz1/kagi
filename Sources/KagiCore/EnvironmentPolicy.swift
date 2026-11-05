import Foundation

/// 继承环境里能让子进程额外加载代码、或在启动时执行别的命令的变量。
///
/// 授权说明只写命令本身，看不出这些变量：`NODE_OPTIONS=--require=/tmp/x.js kagi run … -- node send.js`
/// 在弹窗里只是 `node send.js`。所以 run 默认不把它们交给子进程；确实需要时用 `--pass-env 变量名`
/// 显式保留，保留的变量连同值写进授权说明，由用户判断。
///
/// 这是缩小绕过面的保守名单，不是沙箱：PATH、HOME、配置文件、脚本和可执行文件内容仍不在授权绑定范围内。
public enum EnvironmentPolicy {
  /// 按名字完全匹配。
  public static let names: Set<String> = [
    // shell：非交互 bash 读 BASH_ENV；zsh 每次启动都读 $ZDOTDIR/.zshenv；xtrace 下 PS4 会被展开执行。
    "BASH_ENV", "ZDOTDIR", "SHELLOPTS", "BASHOPTS", "PS4",
    // Node.js / Electron
    "NODE_OPTIONS", "NODE_PATH", "NODE_REPL_EXTERNAL_MODULE", "ELECTRON_RUN_AS_NODE",
    // Python
    "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONINSPECT",
    "PYTHONBREAKPOINT", "PYTHONWARNINGS", "PYTHONEXECUTABLE",
    // Ruby / Perl / PHP
    "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB", "PERLLIB", "PERL5DB", "PHPRC", "PHP_INI_SCAN_DIR",
    // JVM
    "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH",
    // Git / SSH：会在 git 操作中启动外部命令。
    "GIT_CONFIG", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_EXEC_PATH", "GIT_ASKPASS", "GIT_PROXY_COMMAND",
    "GIT_EXTERNAL_DIFF", "GIT_TEMPLATE_DIR", "SSH_ASKPASS",
  ]

  /// 按前缀匹配，区分大小写。
  public static let prefixes: [String] = [
    "DYLD_", "LD_", "BASH_FUNC_", "GIT_CONFIG_", "LUA_INIT", "LUA_PATH", "LUA_CPATH",
  ]

  /// 按前缀匹配，不区分大小写：npm 同时认 `npm_config_*` 和 `NPM_CONFIG_*`（如 script-shell、node-options）。
  public static let caseInsensitivePrefixes: [String] = ["npm_config_"]

  public static func isRisky(_ name: String) -> Bool {
    if names.contains(name) { return true }
    if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
    let lower = name.lowercased()
    return caseInsensitivePrefixes.contains { lower.hasPrefix($0.lowercased()) }
  }

  public struct Filtered: Equatable, Sendable {
    /// 交给子进程的继承环境（还没加上本次注入的值）。
    public let environment: [String: String]
    /// 被移除的变量名，已排序。
    public let removed: [String]
    /// 按 keep 保留下来的变量，按名字排序。
    public let kept: [Kept]
  }

  public struct Kept: Equatable, Sendable {
    public let name: String
    public let value: String
  }

  /// 从继承环境里拿掉名单上的变量；keep 里点名的保留。keep 中不存在于继承环境的名字直接忽略。
  public static func filter(_ inherited: [String: String], keep: Set<String>) -> Filtered {
    var environment: [String: String] = [:]
    var removed: [String] = []
    var kept: [Kept] = []
    for (name, value) in inherited {
      if isRisky(name) {
        if keep.contains(name) {
          environment[name] = value
          kept.append(Kept(name: name, value: value))
        } else {
          removed.append(name)
        }
      } else {
        environment[name] = value
      }
    }
    return Filtered(
      environment: environment, removed: removed.sorted(),
      kept: kept.sorted { $0.name < $1.name })
  }
}
