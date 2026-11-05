import LocalAuthentication
import XCTest

@testable import KagiCore

final class DiagnosticsTests: XCTestCase {
  func testWatchdogCancelsAfterTimeoutAndReportsStuckCall() {
    let stuck = expectation(description: "stuck")
    let watchdog = PromptWatchdog(context: LAContext(), timeout: 0.05, grace: 0.05) {
      stuck.fulfill()
    }
    wait(for: [stuck], timeout: 2)
    XCTAssertTrue(watchdog.fired)
    watchdog.finish()
  }

  func testWatchdogStaysQuietWhenCallReturnsInTime() {
    let stuck = expectation(description: "stuck")
    stuck.isInverted = true
    let watchdog = PromptWatchdog(context: LAContext(), timeout: 0.2, grace: 0.05) {
      stuck.fulfill()
    }
    watchdog.finish()
    wait(for: [stuck], timeout: 0.5)
    XCTAssertFalse(watchdog.fired)
  }

  func testCallReturningAfterCancelIsNotReportedAsStuck() {
    let stuck = expectation(description: "stuck")
    stuck.isInverted = true
    let watchdog = PromptWatchdog(context: LAContext(), timeout: 0.05, grace: 1) {
      stuck.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertTrue(watchdog.fired)
    watchdog.finish()
    wait(for: [stuck], timeout: 1.5)
  }

  func testSandboxHintsOnlyReportKnownVariables() {
    XCTAssertEqual(
      Diagnostics.sandboxHints(["CODEX_SANDBOX": "seatbelt", "HOME": "/Users/fake"]),
      ["CODEX_SANDBOX=seatbelt"])
    XCTAssertEqual(Diagnostics.sandboxHints(["PATH": "/usr/bin"]), [])
  }

  func testSecuritySessionAttributeBits() {
    let session = Diagnostics.SecuritySession(id: 7, attributes: 0x0030)
    XCTAssertTrue(session.graphicAccess)
    XCTAssertTrue(session.tty)
    XCTAssertFalse(session.remote)
    XCTAssertFalse(session.root)
    XCTAssertFalse(Diagnostics.SecuritySession(id: 1, attributes: 0x1020).graphicAccess)
  }

  func testTimeoutIsTemporaryAndPointsAtDoctor() {
    let error = Kagi.describe(.timedOut(90), action: .read, byAgent: true)
    XCTAssertEqual(error.code, .tempFail)
    XCTAssertTrue(error.message.contains("90"))
    XCTAssertTrue(error.hint?.contains("kagi doctor --prompt") == true)
  }

  func testConnectionErrorInSandboxMeansBlocked() {
    // Codex 的 seatbelt 拒绝 coreauthd 和 ctkd 时，密钥操作实测返回这个错误。
    let blocked = NSError(
      domain: NSCocoaErrorDomain, code: 4099,
      userInfo: [NSLocalizedDescriptionKey: "Couldn’t communicate with a helper application."])
    guard case .blocked(let detail) = SecureEnclaveBackend.failure(from: blocked, sandboxed: true)
    else { return XCTFail("沙箱里应该算被拦住") }
    XCTAssertTrue(detail.contains("4099"), "要保留系统的原始错误")
    guard case .other = SecureEnclaveBackend.failure(from: blocked, sandboxed: false) else {
      return XCTFail("不在沙箱里不能说成被沙箱拦住")
    }
    guard case .other = SecureEnclaveBackend.failure(from: blocked, sandboxed: nil) else {
      return XCTFail("不确定是否在沙箱里时不能下结论")
    }
  }

  func testUserAndLockErrorsKeepTheirMeaningInSandbox() {
    let cancel = NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue)
    XCTAssertEqual(SecureEnclaveBackend.failure(from: cancel, sandboxed: true), .denied)
    let locked = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
    XCTAssertEqual(SecureEnclaveBackend.failure(from: locked, sandboxed: true), .locked)
  }

  func testBlockedIsTemporaryAndExplainsTheNextStep() {
    let error = Kagi.describe(.blocked("NSCocoaErrorDomain 4099"), action: .read, byAgent: true)
    XCTAssertEqual(error.code, .tempFail)
    XCTAssertTrue(error.message.contains("沙箱"))
    XCTAssertTrue(error.message.contains("命令没有运行"))
    XCTAssertTrue(error.hint?.contains("kagi doctor") == true)
    XCTAssertTrue(error.hint?.contains("不要设法绕开") == true)
    XCTAssertTrue(error.hint?.contains("4099") == true)
    XCTAssertEqual(
      Kagi.describe(.blocked("x"), action: .write, byAgent: false).message.contains("什么都没存"), true)
  }

  func testProcessDiagnosticsRunWithoutPrompting() {
    _ = Diagnostics.isSandboxed()
    _ = Diagnostics.securitySession()
    _ = Diagnostics.canAuthenticate()
    _ = Diagnostics.promptBlockers()
    XCTAssertFalse(Diagnostics.bootstrapManager()?.isEmpty ?? false)
    XCTAssertFalse(Diagnostics.responsibleProcess()?.isEmpty ?? false)
  }
}
