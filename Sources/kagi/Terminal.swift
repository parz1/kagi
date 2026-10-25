import Darwin
import Foundation

/// 终端输入输出。kagi 自己的提示一律写到 stderr，stdout 只留给数据（ls、log、guide）和子进程。
enum Term {
  static let stdinIsTTY = isatty(STDIN_FILENO) == 1
  static let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
  static let stderrIsTTY = isatty(STDERR_FILENO) == 1
  static let colorAllowed = ProcessInfo.processInfo.environment["NO_COLOR"] == nil

  enum Style: String {
    case dim = "2"
    case bold = "1"
    case ok = "32"
    case bad = "31"
    case warn = "33"
  }

  static func paint(_ text: String, _ style: Style?, tty: Bool) -> String {
    guard let style, tty, colorAllowed else { return text }
    return "\u{1B}[\(style.rawValue)m\(text)\u{1B}[0m"
  }

  /// 写一行到 stderr。
  static func say(_ text: String, _ style: Style? = nil) {
    FileHandle.standardError.write(Data((paint(text, style, tty: stderrIsTTY) + "\n").utf8))
  }

  /// 写一行到 stdout。
  static func print(_ text: String, _ style: Style? = nil) {
    FileHandle.standardOutput.write(Data((paint(text, style, tty: stdoutIsTTY) + "\n").utf8))
  }

  /// 从终端读一行，输入时不显示。没有终端时返回 nil。
  static func readHidden(_ prompt: String) -> String? {
    read(prompt, flags: RPP_REQUIRE_TTY)
  }

  /// 从终端读一行，正常显示。
  static func readVisible(_ prompt: String) -> String? {
    read(prompt, flags: RPP_REQUIRE_TTY | RPP_ECHO_ON)
  }

  static let inputLimit = 8192

  static func read(_ prompt: String, flags: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: inputLimit)
    defer { memset_s(&buffer, buffer.count, 0, buffer.count) }
    guard readpassphrase(prompt, &buffer, buffer.count, flags) != nil else { return nil }
    return String(cString: buffer)
  }

  /// 按终端里的显示宽度补空格：汉字和全角标点算两格。
  static func pad(_ text: String, to width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - displayWidth(text)))
  }

  static func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { sum, scalar in
      let v = scalar.value
      let wide =
        (0x1100...0x115F).contains(v) || (0x2E80...0x303F).contains(v) || (0x3040...0xA4CF).contains(v)
        || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
        || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) || v >= 0x20000
      return sum + (wide ? 2 : 1)
    }
  }

  /// 截断到指定的显示宽度，超出时以「…」结尾。
  static func truncate(_ text: String, to width: Int) -> String {
    guard displayWidth(text) > width else { return text }
    var result = ""
    for ch in text {
      if displayWidth(result + String(ch)) > width - 1 { break }
      result.append(ch)
    }
    return result + "…"
  }

  /// 把参数拼回一条能看懂的命令：带空格或特殊字符的参数加单引号。
  static func commandLine(_ argv: [String]) -> String {
    argv.map { arg in
      let safe = !arg.isEmpty && arg.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "_./:=@%+,-".unicodeScalars.contains($0)
      }
      return safe ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
  }

  /// 「10-25 13:58」：本地时间。
  static func shortTime(_ iso: String) -> String {
    localTime(iso, format: "MM-dd HH:mm")
  }

  /// 「2026-10-25 13:58:31」：本地时间，带秒。
  static func longTime(_ iso: String) -> String {
    localTime(iso, format: "yyyy-MM-dd HH:mm:ss")
  }

  static func localTime(_ iso: String, format: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    guard let date = parser.date(from: iso) else { return iso }
    let formatter = DateFormatter()
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}
