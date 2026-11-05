import Foundation
@testable import KagiCore
import XCTest
@testable import KagiGUIBridge

final class GUIBridgeTests: XCTestCase {
  var root: URL!
  var local: LocalStore!
  var backend: SoftwareBackend!
  var bridge: GUIBridge!
  var copied: [String] = []
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("kagi-gui-test-" + UUID().uuidString)
    local = LocalStore(dir: root.appendingPathComponent("local"))
    backend = SoftwareBackend()
    let pending = try Kagi.prepareInit(at: root.appendingPathComponent("vault"),
      deviceName: "FAKE GUI", backend: backend, reason: { $0 })
    try pending.commit(local: local)
    bridge = GUIBridge(local: local, backend: backend, mode: "software", copy: { self.copied.append($0) })
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func call(_ method: String, _ arguments: [String: Any] = [:], version: Int = 1) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: ["version": version, "method": method, "arguments": arguments])
    let reply = bridge.handle(data)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
  }
  func result(_ method: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
    let response = try call(method, args)
    return try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
  }
  func meta(_ archived: Bool = false) -> [String: Any] {
    ["space": "default", "tags": ["test"], "title": "FAKE GUI Key", "archived": archived]
  }
  func create(_ kind: String = "secret", value: String = "FAKE-GUI-SECRET") throws -> [String: Any] {
    _ = try result("unlock")
    let snapshot = try result("create", ["ref": "demo/key", "value": value, "kind": kind, "metadata": meta()])
    return try XCTUnwrap((snapshot["keys"] as? [[String: Any]])?.first)
  }
  func testNoMetadataBeforeUnlockAndExplicitLockClearsIt() throws {
    XCTAssertEqual(try result("snapshot")["status"] as? String, "locked")
    _ = try create()
    _ = try result("lock")
    let snapshot = try result("snapshot")
    XCTAssertEqual((snapshot["keys"] as? [Any])?.count, 0)
    let failure = try call("copySecret", ["ref": "demo/key", "revision": "stale"])
    XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? Int, 75)
    XCTAssertTrue(copied.isEmpty)
  }
  func testCopyIsNativeOnlyAndPayloadNeverContainsSecretOrDeviceBlob() throws {
    let item = try create()
    let response = try result("copySecret", ["ref": "demo/key", "revision": item["revision"]!])
    XCTAssertEqual(response["copied"] as? Bool, true)
    XCTAssertEqual(copied, ["FAKE-GUI-SECRET"])
    let snapshot = try JSONSerialization.data(withJSONObject: result("snapshot"))
    let text = String(decoding: snapshot, as: UTF8.self)
    XCTAssertFalse(text.contains("FAKE-GUI-SECRET"))
    XCTAssertFalse(text.contains(try XCTUnwrap(local.load()).secretKeyBlob))
    let log = try String(contentsOf: local.logURL, encoding: .utf8)
    XCTAssertFalse(log.contains("FAKE-GUI-SECRET"))
  }
  func testDeniedAndLockedNativeOperationsDoNotMutate() throws {
    let item = try create()
    backend.decision = .deny
    let failure = try call("update", ["ref": "demo/key", "revision": item["revision"]!, "metadata": meta(true)])
    XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? Int, 77)
    XCTAssertEqual(try Session(local: local, backend: backend).listings().count, 1)
    backend.decision = .locked
    let denied = try call("copySecret", ["ref": "demo/key", "revision": item["revision"]!])
    XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? Int, 75)
    XCTAssertTrue(copied.isEmpty)
    XCTAssertEqual(try result("snapshot")["status"] as? String, "locked")
  }
  func testStaleRevisionCannotEditAndArchiveCanRestore() throws {
    let item = try create()
    let archived = try result("update", ["ref": "demo/key", "revision": item["revision"]!, "metadata": meta(true)])
    let stale = try call("update", ["ref": "demo/key", "revision": item["revision"]!, "metadata": meta()])
    XCTAssertEqual((stale["error"] as? [String: Any])?["code"] as? Int, 75)
    _ = try result("unlock")
    let current = try XCTUnwrap((archived["keys"] as? [[String: Any]])?.first)
    _ = try result("update", ["ref": "demo/key", "revision": current["revision"]!, "metadata": meta()])
    XCTAssertEqual(try Session(local: local, backend: backend).listings().count, 1)
  }
  func testTOTPReturnsTemporaryCodeButNeverSeedAndCannotCopySeed() throws {
    let seed = "JBSWY3DPEHPK3PXP"
    let item = try create("totp", value: seed)
    let args = ["ref": "demo/key", "revision": item["revision"]!]
    let response = try result("totp", args)
    XCTAssertEqual((response["code"] as? String)?.count, 6)
    XCTAssertNotNil(response["validUntil"])
    let denied = try call("copySecret", args)
    XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? Int, 64)
    XCTAssertTrue(copied.isEmpty)
    XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: result("snapshot")), as: UTF8.self).contains(seed))
  }
  func testProtocolVersionUnknownFieldsAndRawReadAreRejected() throws {
    for (method, args) in [("read", [:]), ("snapshot", ["shell": "FAKE-SECRET"])] {
      let response = try call(method, args)
      XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, 64)
      XCTAssertFalse(String(describing: response).contains("FAKE-SECRET"))
    }
    XCTAssertNotNil(try call("snapshot", version: 2)["error"])
  }
  func testSpaceAndDirectorySyncUseExistingCore() throws {
    _ = try result("unlock")
    _ = try result("space", ["action": "create", "id": "work", "name": "Work"])
    let response = try result("sync", ["remotePath": root.appendingPathComponent("remote").path, "resolutions": [:]])
    XCTAssertNotNil(response["sync"])
    XCTAssertEqual((response["snapshot"] as? [String: Any])?["status"] as? String, "ready")
  }
  func testInterruptedSyncCanBeRecoveredThroughGUIAfterUnlock() throws {
    _ = try create()
    let remotePath = root.appendingPathComponent("remote").path
    _ = try result("sync", ["remotePath": remotePath])
    let session = try Session(local: local, backend: backend)
    let key = try session.unlock(reason: "FAKE recovery test", action: .write, byAgent: false)
    let transport = try DirectorySyncTransport(root: root.appendingPathComponent("remote/" + session.vault.vault))
    let head = try XCTUnwrap(transport.head())
    let archive = try JSONDecoder().decode(SyncArchive.self, from: transport.object(head))
    let snapshot = try archive.open(key: key)
    struct Pending: Encodable { let transport: String; let revision: String; let snapshot: SyncSnapshot }
    let pending = Pending(transport: transport.identity, revision: head, snapshot: snapshot)
    let sealed = try Crypto.seal(try JSONEncoder().encode(pending), key: key,
      binding: Data("kagi-sync-local/1|\(session.vault.vault)|pending".utf8))
    try Data(sealed.utf8).write(to: session.store.root.appendingPathComponent(".sync-pending"))
    _ = try result("lock")
    let recovery = try result("unlock")
    XCTAssertEqual(recovery["status"] as? String, "syncRecovery")
    XCTAssertEqual((recovery["keys"] as? [Any])?.count, 0)
    let completed = try result("sync", ["remotePath": remotePath])
    XCTAssertEqual((completed["snapshot"] as? [String: Any])?["status"] as? String, "ready")
  }
  func testClipboardLeaseDoesNotEraseAnotherApplicationCopy() {
    var generation = 2
    var erased = false
    let lease = ClipboardLease(generation: 1, currentGeneration: { generation }, erase: { erased = true }, observeTermination: false)
    lease.clear()
    XCTAssertFalse(erased)
    generation = 3
    lease.clear()
    XCTAssertFalse(erased)
  }
  func testClipboardLeaseClearsOnlyOnceWhileStillOwned() {
    var generation = 1
    var erasures = 0
    let lease = ClipboardLease(generation: 1, currentGeneration: { generation }, erase: { erasures += 1; generation += 1 }, observeTermination: false)
    lease.clear(); lease.clear()
    XCTAssertEqual(erasures, 1)
  }
  func testUnconfiguredStoreIsExplicitNotFakeFallback() throws {
    bridge = GUIBridge(local: LocalStore(dir: root.appendingPathComponent("empty")), backend: backend)
    let response = try result("snapshot")
    XCTAssertEqual(response["status"] as? String, "unconfigured")
    XCTAssertEqual(response["mode"] as? String, "native")
  }
}
