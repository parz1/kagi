import AppKit
import Darwin
import Foundation

/// 剪贴板：标记成「隐藏、临时」，只留在本机（不进通用剪贴板），到时间自动清除。
enum Clipboard {
  static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  static func copyConcealed(_ text: String, clearAfter seconds: Int) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.prepareForNewContents(with: .currentHostOnly)
    guard pasteboard.setString(text, forType: .string) else { return false }
    pasteboard.setData(Data(), forType: concealed)
    pasteboard.setData(Data(), forType: transient)
    spawnClearer(changeCount: pasteboard.changeCount, seconds: seconds)
    return true
  }

  /// 由后台的 kagi _clear-clipboard 调用：期间剪贴板没被别人改过，才清掉。
  static func clearIfUnchanged(changeCount: Int, after seconds: Int) {
    sleep(UInt32(seconds))
    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount == changeCount {
      pasteboard.clearContents()
    }
  }

  /// 另起一个脱离终端的 kagi 进程负责清除，kagi 自己退出也不影响。
  static func spawnClearer(changeCount: Int, seconds: Int) {
    guard let executable = Bundle.main.executablePath else { return }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let argv = [executable, "_clear-clipboard", String(changeCount), String(seconds)].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    _ = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
  }
}
