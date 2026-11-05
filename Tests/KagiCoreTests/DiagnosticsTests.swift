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

  func testProcessDiagnosticsRunWithoutPrompting() {
    _ = Diagnostics.isSandboxed()
    _ = Diagnostics.securitySession()
    _ = Diagnostics.canAuthenticate()
    _ = Diagnostics.promptBlockers()
  }
}
