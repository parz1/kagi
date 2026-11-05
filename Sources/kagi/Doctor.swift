import CryptoKit
import Foundation
import KagiCore
import LocalAuthentication

/// kagi doctor：排查系统验证框为什么弹不出来（AUTH-001）。
///
/// 只读进程环境，不打开库、不读任何值。`--prompt` 额外弹两次测试验证框：一次只验证「设备主人」，
/// 一次用用完即弃的临时 Secure Enclave 密钥走真实取值的路径，都和库里的钥匙无关。
/// 在自己的终端和 agent 里各跑一次，对比输出就能看出启动上下文的差别。
enum Doctor {
  enum PromptResult: String {
    case approved, denied, locked, blocked, timedOut, unavailable, error
  }

  typealias Outcome = (result: PromptResult, detail: String, seconds: Double)

  static func run(_ args: [String]) throws -> Int32 {
    var parser = ArgParser(args)
    let json = parser.flag("--json")
    let prompt = parser.flag("--prompt")
    try parser.finish()

    let report = Report(
      json: json,
      initiator: Initiator.current(),
      sandboxed: Diagnostics.isSandboxed(),
      hints: Diagnostics.sandboxHints(),
      bootstrapManager: Diagnostics.bootstrapManager(),
      responsibleProcess: Diagnostics.responsibleProcess(),
      session: Diagnostics.securitySession(),
      screenLocked: Diagnostics.isScreenLocked(),
      auth: Diagnostics.canAuthenticate(),
      timeout: try Commands.authTimeout(),
      configured: (try? Commands.localStore().load()) != nil)

    guard prompt else { return report.emit(prompt: nil, keyPrompt: nil) }

    if !json { Term.say("第一步：弹出测试验证框，最多等 \(report.timeout) 秒…", .dim) }
    let first = testPrompt(initiator: report.initiator, timeout: report.timeout)
    // 第一步没通过时不再弹第二次：用户已经取消，或者这个环境根本弹不出来。
    guard first.result == .approved else { return report.emit(prompt: first, keyPrompt: nil) }

    if !json { Term.say("第二步：用临时密钥走真实取值的路径，再弹一次，最多等 \(report.timeout) 秒…", .dim) }
    let second = testKeyPrompt(initiator: report.initiator, timeout: report.timeout) {
      // 取消验证后密钥操作仍然不返回：先把已知结果交代清楚，再退出。
      let stuck: Outcome = (.timedOut, "取消验证后系统调用仍没有返回", Double(report.timeout))
      exit(report.emit(prompt: first, keyPrompt: stuck))
    }
    return report.emit(prompt: first, keyPrompt: second)
  }

  /// 只做「设备主人验证」，不使用库里的钥匙。超时后取消，和取值时的看门狗一致。
  static func testPrompt(initiator: Initiator, timeout: Int) -> Outcome {
    let context = LAContext()
    defer { context.invalidate() }
    let reason = "kagi doctor：测试能否弹出验证框，不读取任何密钥（\(Reason.by(initiator))）"
    let started = Date()
    var error: NSError?
    let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    // 沙箱优先：解了锁也弹不出来，先告诉用户真正要处理的事。
    if !available, Diagnostics.isSandboxed() == true {
      return (.blocked, error.map(describe) ?? "不能验证", 0)
    }
    if Diagnostics.isScreenLocked() == true { return (.locked, "屏幕锁着", 0) }
    guard available else { return (.unavailable, error.map(describe) ?? "不能验证", 0) }
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

  /// 走和真实取值相同的后端和线程：由 Secure Enclave 密钥操作内部触发验证（AUTH-001 卡住的地方）。
  /// 用的是临时生成的密钥和假数据，密钥只在内存里，用完即弃，和库无关。
  static func testKeyPrompt(
    initiator: Initiator, timeout: Int, onStuck: @escaping @Sendable () -> Void
  ) -> Outcome {
    let backend = SecureEnclaveBackend(promptTimeout: TimeInterval(timeout), onStuck: onStuck)
    let started = Date()
    func elapsed() -> Double { Date().timeIntervalSince(started) }
    guard backend.isAvailable else {
      let result: PromptResult = Diagnostics.isSandboxed() == true ? .blocked : .unavailable
      return (result, "Secure Enclave 不可用", 0)
    }
    let reason = "kagi doctor：测试密钥操作能否弹出验证框，用临时密钥，不读取任何密钥（\(Reason.by(initiator))）"
    let binding = Data("kagi-doctor-test".utf8)
    let fake = Data("FAKE-KAGI-DOCTOR-NOT-A-SECRET".utf8)
    do {
      let pair = try backend.makeKey(requiresUserPresence: true)
      let box = try Crypto.hpkeSeal(fake, to: pair.publicKey, binding: binding)
      let opened = try backend.openWithPresence(box, blob: pair.blob, binding: binding, reason: reason)
      return opened == fake ? (.approved, "已通过", elapsed()) : (.error, "解出来的内容不对", elapsed())
    } catch KeyFailure.denied {
      return (.denied, "已取消", elapsed())
    } catch KeyFailure.locked {
      return (.locked, "屏幕锁着", elapsed())
    } catch KeyFailure.timedOut(let seconds) {
      return (.timedOut, "\(seconds) 秒内没有完成，已取消", elapsed())
    } catch KeyFailure.blocked(let detail) {
      return (.blocked, detail, elapsed())
    } catch {
      return (.error, "\(error)", elapsed())
    }
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

  /// 这次诊断看到的环境。提示框的结果另外传入：密钥操作卡死时要从看门狗线程提前输出。
  struct Report: Sendable {
    let json: Bool
    let initiator: Initiator
    let sandboxed: Bool?
    let hints: [String]
    let bootstrapManager: String?
    let responsibleProcess: String?
    let session: Diagnostics.SecuritySession?
    let screenLocked: Bool?
    let auth: (ok: Bool, detail: String)
    let timeout: Int
    let configured: Bool

    /// 输出报告，返回退出码。
    func emit(prompt: Outcome?, keyPrompt: Outcome?) -> Int32 {
      if json {
        printJSON(prompt: prompt, keyPrompt: keyPrompt)
      } else {
        printText(prompt: prompt, keyPrompt: keyPrompt)
      }
      switch (keyPrompt ?? prompt)?.result {
      case nil, .approved: return 0
      case .denied: return ExitCode.denied.rawValue
      case .locked, .blocked, .timedOut: return ExitCode.tempFail.rawValue
      case .unavailable, .error: return ExitCode.software.rawValue
      }
    }

    private func printJSON(prompt: Outcome?, keyPrompt: Outcome?) {
      func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
      func encode(_ outcome: Outcome) -> [String: Any] {
        [
          "result": outcome.result.rawValue,
          "detail": outcome.detail,
          "seconds": (outcome.seconds * 10).rounded() / 10,
        ]
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
        "bootstrapManager": optional(bootstrapManager),
        "responsibleProcess": optional(responsibleProcess),
        "screenLocked": screenLocked.map { $0 as Any } ?? NSNull(),
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
      if let prompt { report["prompt"] = encode(prompt) }
      if let keyPrompt { report["keyPrompt"] = encode(keyPrompt) }
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      else { return }
      Term.print(String(decoding: data, as: UTF8.self))
    }

    private func printText(prompt: Outcome?, keyPrompt: Outcome?) {
      func line(_ ok: Bool?, _ title: String, _ value: String) {
        let mark = ok == nil ? "·" : ok! ? "✓" : "✗"
        let style: Term.Style? = ok == false ? .bad : nil
        Term.print("\(mark) \(title)：\(value)", style)
      }
      func show(_ title: String, _ outcome: Outcome) {
        let text =
          switch outcome.result {
          case .approved: "弹出并通过"
          case .denied: "弹出后被取消"
          case .locked: "屏幕锁着"
          case .blocked: "被沙箱拦住"
          case .timedOut: "没有完成"
          case .unavailable: "不能验证"
          case .error: "出错"
          }
        line(
          outcome.result == .approved || outcome.result == .denied, title,
          "\(text)，用时 \(String(format: "%.1f", outcome.seconds)) 秒（\(outcome.detail)）")
      }
      Term.print(Texts.version, .bold)
      line(nil, "发起方", "\(initiator.label)\(initiator.isAgent ? "（agent）" : "")")
      line(nil, "进程链", initiator.chain.joined(separator: " ← "))
      line(nil, "责任进程", responsibleProcess ?? "未知")
      line(nil, "引导命名空间", bootstrapManager ?? "未知")
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
      if let screenLocked {
        line(!screenLocked, "屏幕", screenLocked ? "锁着" : "没锁")
      } else {
        line(nil, "屏幕", "未知")
      }
      line(SecureEnclave.isAvailable, "Secure Enclave", SecureEnclave.isAvailable ? "可用" : "不可用")
      line(auth.ok, "系统验证", auth.ok ? "可用（\(auth.detail)）" : auth.detail)
      line(nil, "本机库", configured ? "已设置" : "还没设置")
      line(nil, "验证超时", "\(timeout) 秒（KAGI_AUTH_TIMEOUT）")
      if let prompt { show("测试验证框", prompt) }
      if let keyPrompt { show("密钥操作验证框", keyPrompt) }

      var advice: [String] = []
      if sandboxed == true {
        advice.append("kagi 在沙箱里运行，连不上系统验证和 Secure Enclave，验证框弹不出来，重试没有用。")
        advice.append("请让 kagi 在沙箱外运行，例如 Codex 在 ~/.codex/rules/default.rules 里加一行：prefix_rule(pattern=[\"kagi\"], decision=\"allow\")")
        advice.append("这样 kagi run 启动的命令也在沙箱外，每次运行前都要你在系统验证框里确认这条命令。")
      }
      if session?.graphicAccess == false {
        advice.append("当前会话没有图形界面，验证框无法显示。请在这台 Mac 的桌面会话里运行。")
      }
      if screenLocked == true {
        advice.append("屏幕锁着，验证框显示不出来。请解锁后再试。")
      }
      if prompt?.result == .timedOut {
        advice.append("测试验证框没有完成：可能没被注意到，也可能没显示出来（AUTH-001）。请在自己的终端里再运行一次 kagi doctor --prompt 对比。")
      }
      if keyPrompt?.result == .timedOut {
        advice.append("测试验证框能弹，密钥操作的验证框却没有完成：可能没被注意到，否则问题在 Secure Enclave 操作本身（AUTH-001），请记下这份输出。")
      }
      if prompt == nil {
        advice.append("加 --prompt 可以实际弹两次测试验证框（不读取任何密钥）。")
      }
      for item in advice { Term.print("→ \(item)", .warn) }
    }
  }
}
