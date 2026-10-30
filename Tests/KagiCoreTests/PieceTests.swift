import Foundation
import XCTest

@testable import KagiCore

final class RecoveryKeyTests: XCTestCase {
  func testDisplayIsEightGroupsOfFour() {
    let key = RecoveryKey.generate()
    let groups = key.displayText.split(separator: "-")
    XCTAssertEqual(groups.count, 8)
    XCTAssertTrue(groups.allSatisfy { $0.count == 4 })
    XCTAssertEqual(key.lastGroup, String(groups.last!))
  }

  func testParsingForgivesCaseDashesAndLookalikes() throws {
    let key = RecoveryKey.generate()
    let sloppy = key.displayText.lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "0", with: "o")
      .replacingOccurrences(of: "1", with: "l")
    XCTAssertEqual(try RecoveryKey(parsing: sloppy), key)
  }

  func testOneWrongCharacterFailsTheChecksum() {
    let key = RecoveryKey.generate()
    var chars = Array(key.displayText)
    chars[5] = chars[5] == "A" ? "B" : "A"
    XCTAssertThrowsError(try RecoveryKey(parsing: String(chars))) { error in
      XCTAssertEqual((error as? KagiError)?.code, .dataError)
    }
  }

  func testBase32RoundTrip() {
    for length in [1, 5, 10, 16, 20] {
      let data = Crypto.randomBytes(length)
      XCTAssertEqual(Base32.decode(Base32.encode(data))?.prefix(length), data)
    }
    XCTAssertNil(Base32.decode("UUUU"), "U 不在字母表里")
  }
}

final class RefTests: XCTestCase {
  func testValidRefs() throws {
    for text in ["resend/api-key", "railway/db-url", "apple/apns-key.p8", "a", "x_1/y-2"] {
      XCTAssertEqual(try Ref(text).path, text)
    }
  }

  func testInvalidRefs() {
    for text in [
      "", "Resend/api-key", "/abs", "a//b", "a/../b", "../x", "a b", "a/", "-x", "中文/key",
    ] {
      XCTAssertThrowsError(try Ref(text), text)
    }
  }

  func testClosestSuggestion() {
    let refs = ["resend/api-key", "railway/token", "railway/db-url"]
    XCTAssertEqual(Ref.closest(to: "resend/api-kye", in: refs), "resend/api-key")
    XCTAssertNil(Ref.closest(to: "github/token-for-ci", in: refs))
  }
}

final class RedactorTests: XCTestCase {
  let secret = "FAKE-VALUE-0001-not-a-secret"
  var redactor: Redactor { Redactor(values: [("demo/fake-token", Data(secret.utf8))]) }

  func run(_ chunks: [String], _ r: Redactor) -> String {
    var out = Data()
    for chunk in chunks { out += r.feed(Data(chunk.utf8)) }
    out += r.finish()
    return String(decoding: out, as: UTF8.self)
  }

  func testReplacesWholeValue() {
    XCTAssertEqual(run(["key=\(secret)\n"], redactor), "key=‹kagi:demo/fake-token›\n")
  }

  func testReplacesValueSplitAcrossChunks() {
    let line = "Using \(secret) now\n"
    for cut in 1..<line.count {
      let i = line.index(line.startIndex, offsetBy: cut)
      XCTAssertEqual(
        run([String(line[..<i]), String(line[i...])], redactor),
        "Using ‹kagi:demo/fake-token› now\n")
    }
  }

  func testDoesNotHoldBackUnrelatedOutput() {
    let r = redactor
    XCTAssertEqual(String(decoding: r.feed(Data("Password: ".utf8)), as: UTF8.self), "Password: ")
  }

  func testHoldsBackAPossiblePrefixUntilFinish() {
    let r = redactor
    XCTAssertEqual(String(decoding: r.feed(Data("FAKE-VAL".utf8)), as: UTF8.self), "")
    XCTAssertEqual(String(decoding: r.finish(), as: UTF8.self), "FAKE-VAL")
  }

  func testShortValuesAreNotRedacted() {
    let r = Redactor(values: [("demo/short", Data("abc".utf8))])
    XCTAssertEqual(run(["abcabc"], r), "abcabc")
  }

  func testOTPThatPrefixesAnotherSecretDoesNotLeakAcrossChunks() {
    let values = [
      ("demo/otp", Data("755224".utf8)), ("demo/api", Data("755224-FAKE-API-KEY".utf8)),
    ]
    let redactor = Redactor(values: values)
    XCTAssertTrue(redactor.feed(Data("755224".utf8)).isEmpty)
    let output = redactor.feed(Data("-FAKE-API-KEY".utf8)) + redactor.finish()
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "‹kagi:demo/api›")
    let shortOnly = Redactor(values: values)
    XCTAssertTrue(shortOnly.feed(Data("755224".utf8)).isEmpty)
    XCTAssertEqual(String(decoding: shortOnly.finish(), as: UTF8.self), "‹kagi:demo/otp›")
  }

  func testAuditCanRedactEvenOneByteValues() {
    let r = Redactor(values: [("demo/short", Data("x".utf8))], minimumLength: 1)
    XCTAssertEqual(r.redact("echo x"), "echo ‹kagi:demo/short›")
  }

  func testRedactsStrings() {
    XCTAssertEqual(redactor.redact("echo \(secret) | x"), "echo ‹kagi:demo/fake-token› | x")
  }
}

final class InitiatorTests: XCTestCase {
  func testExtractsClaudeCodeEvalCommand() {
    let script =
      "source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'cd ~/Projects/kotolog && kagi run --stdin resend/api-key -- railway variable set RESEND_API_KEY --stdin --skip-deploys' < /dev/null && pwd -P >| /tmp/claude-cwd"
    XCTAssertEqual(
      Initiator.extractEval(script),
      "cd ~/Projects/kotolog && kagi run --stdin resend/api-key -- railway variable set RESEND_API_KEY --stdin --skip-deploys"
    )
  }

  func testExtractsEvalWithEscapedQuotes() {
    let script = #"eval 'cat <<'"'"'EOF'"'"' | kagi set demo/x --stdin' < /dev/null"#
    XCTAssertEqual(Initiator.extractEval(script), "cat <<'EOF' | kagi set demo/x --stdin")
  }

  func testNoEval() {
    XCTAssertNil(Initiator.extractEval("kagi ls"))
  }

  func testAppName() {
    XCTAssertEqual(Initiator.appName("/Applications/iTerm.app/Contents/MacOS/iTerm2"), "iTerm")
    XCTAssertEqual(
      Initiator.appName("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
      "Terminal")
    XCTAssertNil(Initiator.appName("/bin/zsh"))
  }
}
