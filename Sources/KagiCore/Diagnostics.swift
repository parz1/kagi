import CoreGraphics
import Darwin
import Foundation
import LocalAuthentication

/// 诊断系统验证框为什么弹不出来（AUTH-001）。只读进程环境，不碰库、不读任何值。
///
/// sandbox_check、SessionGetInfo 按符号名动态取得：前者是系统私有接口，后者的头文件类型在不同 SDK 里导入方式不同。
/// 取不到时返回 nil，调用方显示「未知」。
public enum Diagnostics {
  private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

  /// 当前进程是否运行在 macOS 沙箱（seatbelt / App Sandbox）里。
  public static func isSandboxed() -> Bool? {
    typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    guard let symbol = dlsym(defaultHandle, "sandbox_check") else { return nil }
    return unsafeBitCast(symbol, to: Check.self)(getpid(), nil, 0) != 0
  }

  /// 已知 agent 沙箱在子进程里留下的环境变量（名字和值，不含其他环境）。
  public static func sandboxHints(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    ["CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "APP_SANDBOX_CONTAINER_ID"]
      .compactMap { name in environment[name].map { "\(name)=\($0)" } }
  }

  /// 屏幕现在是否锁着。这个键没有文档但长期稳定；取不到会话信息（如沙箱、无图形会话）时返回 nil。
  public static func isScreenLocked() -> Bool? {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  /// launchd 给当前进程的引导命名空间：桌面会话是 Aqua，后台任务是 Background 等。
  public static func bootstrapManager() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["managername"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  /// macOS 认为对当前进程负责的进程名（系统按它判断权限、显示来源）。系统私有接口，取不到时返回 nil。
  public static func responsibleProcess() -> String? {
    typealias Get = @convention(c) (pid_t) -> pid_t
    guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else {
      return nil
    }
    let pid = unsafeBitCast(symbol, to: Get.self)(getpid())
    guard pid > 0 else { return nil }
    return Initiator.executablePath(pid).map { ($0 as NSString).lastPathComponent }
  }

  public struct SecuritySession: Equatable, Sendable {
    public let id: UInt32
    /// 能否使用图形界面。没有时（ssh 登录、守护进程）系统验证框弹不出来。
    public let graphicAccess: Bool
    public let tty: Bool
    public let remote: Bool
    public let root: Bool

    public init(id: UInt32, attributes: UInt32) {
      self.id = id
      graphicAccess = attributes & 0x0010 != 0
      tty = attributes & 0x0020 != 0
      remote = attributes & 0x1000 != 0
      root = attributes & 0x0001 != 0
    }
  }

  /// 当前进程所在的安全会话（Security 框架的 SessionGetInfo）。
  public static func securitySession() -> SecuritySession? {
    typealias GetInfo = @convention(c) (
      UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?
    ) -> Int32
    guard let symbol = dlsym(defaultHandle, "SessionGetInfo") else { return nil }
    var id: UInt32 = 0
    var attributes: UInt32 = 0
    // callerSecuritySession = (SecuritySessionId)-1
    guard unsafeBitCast(symbol, to: GetInfo.self)(UInt32.max, &id, &attributes) == 0 else {
      return nil
    }
    return SecuritySession(id: id, attributes: attributes)
  }

  /// LocalAuthentication 认为现在能否做「设备主人验证」（指纹或登录密码），以及不能时的原因。
  public static func canAuthenticate() -> (ok: Bool, detail: String) {
    let context = LAContext()
    defer { context.invalidate() }
    var error: NSError?
    let ok = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    let biometry =
      switch context.biometryType {
      case .touchID: "Touch ID"
      case .faceID: "Face ID"
      case .opticID: "Optic ID"
      default: "无生物识别"
      }
    if ok { return (true, biometry) }
    return (false, error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "未知原因")
  }

  /// 超时说明里附加的线索：屏幕锁着、在沙箱里或没有图形会话时，验证框多半显示不出来。
  public static func promptBlockers() -> [String] {
    var result: [String] = []
    if isScreenLocked() == true {
      result.append("屏幕锁着，验证框显示不出来。")
    }
    if isSandboxed() == true {
      let hints = sandboxHints()
      result.append(
        "kagi 运行在沙箱里" + (hints.isEmpty ? "" : "（\(hints.joined(separator: "，"))）")
          + "，系统验证框可能被拦截。")
    }
    if let session = securitySession(), !session.graphicAccess {
      result.append("当前会话不能使用图形界面（例如通过 ssh 运行），系统验证框无法显示。")
    }
    return result
  }
}

/// 系统验证的看门狗：超时后取消 LAContext，让卡住的 Secure Enclave 调用以失败返回；
/// 取消后仍不返回时调用 onStuck（CLI 用它直接退出，GUI 不设置）。
final class PromptWatchdog: @unchecked Sendable {
  let timeout: TimeInterval
  private let lock = NSLock()
  private var done = false
  private var didFire = false
  private let finished = DispatchSemaphore(value: 0)

  init(
    context: LAContext, timeout: TimeInterval, grace: TimeInterval = 5,
    onStuck: (@Sendable () -> Void)?
  ) {
    self.timeout = timeout
    DispatchQueue.global(qos: .utility).async { [self] in
      guard finished.wait(timeout: .now() + timeout) == .timedOut else { return }
      let fire = lock.withLock {
        didFire = !done
        return didFire
      }
      guard fire else { return }
      context.invalidate()
      if finished.wait(timeout: .now() + grace) == .timedOut { onStuck?() }
    }
  }

  /// 是否已经因为超时取消了验证。
  var fired: Bool { lock.withLock { didFire } }

  /// 验证调用已经返回（成功或失败）。
  func finish() {
    lock.withLock { done = true }
    finished.signal()
  }
}
