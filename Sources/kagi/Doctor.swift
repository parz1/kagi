import CryptoKit
import Foundation
import KagiCore
import LocalAuthentication

/// kagi doctor：排查系统验证框为什么弹不出来（AUTH-001）。
///
/// 只读进程环境，不打开库、不读任何值。`--prompt` 额外弹一次测试验证框，只验证「设备主人」，
/// 和任何密钥都无关。在自己的终端和 agent 里各跑一次，对比输出就能看出启动上下文的差别。
enum Doctor {
  enum PromptResult: String {
    case approved, denied, locked, timedOut, unavailable, error
  }

  static func run(_ args: [String]) throws -> Int32 {
    var parser = ArgParser(args)
    let json = parser.flag("--json")
    let prompt = parser.flag("--prompt")
    try parser.finish()

    let initiator = Initiator.current()
    let sandboxed = Diagnostics.isSandboxed()
    let hints = Diagnostics.sandboxHints()
    let session = Diagnostics.securitySession()
    let auth = Diagnostics.canAuthenticate()
    let timeout = try Commands.authTimeout()
    let configured = (try? Commands.localStore().load()) != nil

    var outcome: (result: PromptResult, detail: String, seconds: Double)?
    if prompt {
      if !json { Term.say("正在弹出测试验证框，最多等 \(timeout) 秒…", .dim) }
      outcome = testPrompt(initiator: initiator, timeout: timeout)
    }

    var report: [String: Any] = [
      "version": Texts.version,
      "initiator": [
        "label": initiator.label,
        "isAgent": initiator.isAgent,
        "chain": initiator.chain,
      ] as [String: Any],
      "sandboxed": sandboxed.map { $0 as Any } ?? NSNull(),
      "sandboxHints": hints,
      "secureEnclave": SecureEnclave.isAvailable,
      "localAuthentication": ["ok": auth.ok, "detail": auth.detail] as [String: Any],
      "stdinIsTTY": isatty(STDIN_FILENO) == 1,
      "stdoutIsTTY": isatty(STDOUT_FILENO) == 1,
      "configured": configured,
      "authTimeoutSeconds": timeout,
    ]
    if let session {
      report["securitySession"] = [
        "id": session.id,
        "graphicAccess": session.graphicAccess,
        "tty": session.tty,
        "remote": session.remote,
        "root": session.root,
      ] as [String: Any]
    } else {
      report["securitySession"] = NSNull()
    }
    if let outcome {
      report["prompt"] = [
        "result": outcome.result.rawValue,
        "detail": outcome.detail,
        "seconds": (outcome.seconds * 10).rounded() / 10,
      ] as [String: Any]
    }

    if json {
      let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      Term.print(String(decoding: data, as: UTF8.self))
    } else {
      printReport(
        initiator: initiator, sandboxed: sandboxed, hints: hints, session: session, auth: auth,
        configured: configured, timeout: timeout, outcome: outcome)
    }

    switch outcome?.result {
    case nil, .approved: return 0
    case .denied: return ExitCode.denied.rawValue
    case .locked, .timedOut: return ExitCode.tempFail.rawValue
    case .unavailable, .error: return ExitCode.software.rawValue
    }
  }

  /// 只做「设备主人验证」，不使用库里的钥匙。超时后取消，和取值时的看门狗一致。
  static func testPrompt(initiator: Initiator, timeout: Int)
    -> (result: PromptResult, detail: String, seconds: Double)
  {
    let context = LAContext()
    defer { context.invalidate() }
    let reason = "kagi doctor：测试能否弹出验证框，不读取任何密钥（\(Reason.by(initiator))）"
    let started = Date()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      return (.unavailable, error.map(describe) ?? "不能验证", 0)
    }
    let done = DispatchSemaphore(value: 0)
    let box = PromptBox()
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
      box.set(ok: ok, error: error)
      done.signal()
    }
    if done.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
      context.invalidate()
      _ = done.wait(timeout: .now() + 5)
      return (.timedOut, "\(timeout) 秒内没有完成，已取消", Date().timeIntervalSince(started))
    }
    let elapsed = Date().timeIntervalSince(started)
    let (ok, failure) = box.get()
    if ok { return (.approved, "已通过", elapsed) }
    guard let ns = failure.map({ $0 as NSError }) else { return (.error, "未知错误", elapsed) }
    let result: PromptResult =
      switch (ns.domain, ns.code) {
      case (LAError.errorDomain, LAError.userCancel.rawValue),
        (LAError.errorDomain, LAError.systemCancel.rawValue),
        (LAError.errorDomain, LAError.appCancel.rawValue),
        (LAError.errorDomain, LAError.authenticationFailed.rawValue),
        (LAError.errorDomain, LAError.userFallback.rawValue):
        .denied
      case (LAError.errorDomain, LAError.notInteractive.rawValue):
        .locked
      default:
        .error
      }
    return (result, describe(ns), elapsed)
  }

  static func describe(_ error: NSError) -> String {
    "\(error.domain) \(error.code) \(error.localizedDescription)"
  }

  final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ok = false
    private var error: Error?
    func set(ok: Bool, error: Error?) {
      lock.withLock {
        self.ok = ok
        self.error = error
      }
    }
    func get() -> (Bool, Error?) { lock.withLock { (ok, error) } }
  }

  static func printReport(
    initiator: Initiator, sandboxed: Bool?, hints: [String],
    session: Diagnostics.SecuritySession?, auth: (ok: Bool, detail: String), configured: Bool,
    timeout: Int, outcome: (result: PromptResult, detail: String, seconds: Double)?
  ) {
    func line(_ ok: Bool?, _ title: String, _ value: String) {
      let mark = ok == nil ? "·" : ok! ? "✓" : "✗"
      let style: Term.Style? = ok == false ? .bad : nil
      Term.print("\(mark) \(title)：\(value)", style)
    }
    Term.print(Texts.version, .bold)
    line(nil, "发起方", "\(initiator.label)\(initiator.isAgent ? "（agent）" : "")")
    line(nil, "进程链", initiator.chain.joined(separator: " ← "))
    var sandboxText = "未知"
    if let sandboxed {
      sandboxText = sandboxed ? "是" : "否"
      if sandboxed, !hints.isEmpty { sandboxText += "（\(hints.joined(separator: "，"))）" }
    }
    line(sandboxed.map { !$0 }, "沙箱", sandboxText)
    if let session {
      line(
        session.graphicAccess, "图形会话",
        session.graphicAccess ? "可用" : "不可用" + (session.remote ? "（远程登录）" : ""))
    } else {
      line(nil, "图形会话", "未知")
    }
    line(SecureEnclave.isAvailable, "Secure Enclave", SecureEnclave.isAvailable ? "可用" : "不可用")
    line(auth.ok, "系统验证", auth.ok ? "可用（\(auth.detail)）" : auth.detail)
    line(nil, "本机库", configured ? "已设置" : "还没设置")
    line(nil, "验证超时", "\(timeout) 秒（KAGI_AUTH_TIMEOUT）")
    if let outcome {
      let text =
        switch outcome.result {
        case .approved: "弹出并通过"
        case .denied: "弹出后被取消"
        case .locked: "屏幕锁着"
        case .timedOut: "没有完成"
        case .unavailable: "不能验证"
        case .error: "出错"
        }
      line(
        outcome.result == .approved || outcome.result == .denied, "测试验证框",
        "\(text)，用时 \(String(format: "%.1f", outcome.seconds)) 秒（\(outcome.detail)）")
    }

    var advice: [String] = []
    if sandboxed == true {
      advice.append("kagi 在沙箱里运行，系统验证框可能被拦截。请在 agent 的设置里允许 kagi 在沙箱外运行。")
    }
    if session?.graphicAccess == false {
      advice.append("当前会话没有图形界面，验证框无法显示。请在这台 Mac 的桌面会话里运行。")
    }
    if outcome?.result == .timedOut {
      advice.append("测试验证框没有完成，多半没有显示出来（AUTH-001）。请在自己的终端里再运行一次 kagi doctor --prompt 对比。")
    }
    if outcome == nil {
      advice.append("加 --prompt 可以实际弹一次测试验证框（不读取任何密钥）。")
    }
    for item in advice { Term.print("→ \(item)", .warn) }
  }
}
