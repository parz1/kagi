import Darwin
import Foundation

/// 谁发起了这条 kagi 命令：从父进程往上找。这只是写给人看的提示，恶意程序可以伪造进程名，不能当安全边界。
public struct Initiator: Sendable {
  /// 写进指纹框和使用记录的名字，比如「Claude Code」「终端」。
  public let label: String
  public let isAgent: Bool
  /// 进程名，从父进程往上，最多 10 层。
  public let chain: [String]
  /// 父 shell 收到的整条命令（`zsh -c` 后面那段）；Claude Code 包了一层 eval，会剥出原文。
  public let shellCommand: String?

  public init(label: String, isAgent: Bool, chain: [String], shellCommand: String?) {
    self.label = label
    self.isAgent = isAgent
    self.chain = chain
    self.shellCommand = shellCommand
  }

  static let agents: [String: String] = [
    "claude": "Claude Code",
    "codex": "Codex",
    "cursor-agent": "Cursor",
    "gemini": "Gemini CLI",
    "opencode": "opencode",
  ]

  static let apps: [String: String] = [
    "Terminal": "终端",
    "iTerm": "iTerm2",
    "iTerm2": "iTerm2",
    "Visual Studio Code": "VS Code",
    "Code": "VS Code",
    "Claude": "Claude 应用里的终端",
  ]

  static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]

  public static func current() -> Initiator {
    var nodes: [(pid: pid_t, path: String)] = []
    var pid = getppid()
    while pid > 1, nodes.count < 10 {
      nodes.append((pid, executablePath(pid) ?? "pid \(pid)"))
      guard let parent = parentPID(pid), parent != pid else { break }
      pid = parent
    }
    let chain = nodes.map { ($0.path as NSString).lastPathComponent }

    var shellCommand: String?
    if let first = nodes.first, shells.contains(chain[0]), let args = arguments(first.pid),
      let dashC = args.firstIndex(of: "-c"), dashC + 1 < args.count
    {
      let script = args[dashC + 1]
      shellCommand = extractEval(script) ?? script
    }

    if let agent = chain.lazy.compactMap({ agents[$0] }).first {
      return Initiator(label: agent, isAgent: true, chain: chain, shellCommand: shellCommand)
    }
    if let app = nodes.lazy.compactMap({ appName($0.path) }).first {
      return Initiator(label: apps[app] ?? app, isAgent: false, chain: chain, shellCommand: shellCommand)
    }
    return Initiator(label: "终端", isAgent: false, chain: chain, shellCommand: shellCommand)
  }

  /// /Applications/iTerm.app/Contents/MacOS/iTerm2 → iTerm
  static func appName(_ path: String) -> String? {
    guard let range = path.range(of: ".app/Contents/MacOS/") else { return nil }
    return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
  }

  /// 从 `… && eval '<命令>' < /dev/null && …` 里取出 eval 的那段原文。
  /// 单引号字符串里的单引号写成 '"'"'，这里拼回去。
  public static func extractEval(_ script: String) -> String? {
    guard let start = script.range(of: "eval '") else { return nil }
    var result = ""
    var i = script.index(before: start.upperBound)  // 指向开头那个单引号
    while i < script.endIndex {
      let c = script[i]
      if c == "'" {
        guard let close = script[script.index(after: i)...].firstIndex(of: "'") else { return nil }
        result += script[script.index(after: i)..<close]
        i = script.index(after: close)
      } else if c == "\"" {
        var j = script.index(after: i)
        while j < script.endIndex, script[j] != "\"" {
          if script[j] == "\\", script.index(after: j) < script.endIndex {
            j = script.index(after: j)
          }
          result.append(script[j])
          j = script.index(after: j)
        }
        guard j < script.endIndex else { return nil }
        i = script.index(after: j)
      } else {
        break
      }
    }
    return result.isEmpty ? nil : result
  }

  static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }

  /// KERN_PROCARGS2：argc、可执行文件路径、填充的 0、argc 个参数，再往后是环境变量（不读）。
  static func arguments(_ pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = 4
    while i < size, buffer[i] != 0 { i += 1 }
    while i < size, buffer[i] == 0 { i += 1 }
    var args: [String] = []
    while i < size, args.count < Int(argc) {
      let start = i
      while i < size, buffer[i] != 0 { i += 1 }
      args.append(String(decoding: buffer[start..<i], as: UTF8.self))
      i += 1
    }
    return args
  }
}
