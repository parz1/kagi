import CryptoKit
import Foundation
import XCTest
@testable import KagiCore

final class SyncTests: XCTestCase {
  var root: URL!
  var a: Session!
  var b: Session!
  var backend: SoftwareBackend!
  var key: SymmetricKey!
  var remote: DirectorySyncTransport!
  var recoveryKey: RecoveryKey!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("kagi-sync-tests-" + UUID().uuidString)
    backend = SoftwareBackend()
    let pending = try Kagi.prepareInit(at: root.appendingPathComponent("a"), deviceName: "A",
      backend: backend, reason: { $0 })
    let localA = LocalStore(dir: root.appendingPathComponent("local-a"))
    recoveryKey = pending.recoveryKey
    try pending.commit(local: localA)
    a = try Session(local: localA, backend: backend)
    key = try a.unlock(reason: "FAKE", action: .write, byAgent: false)
    try FileManager.default.copyItem(at: a.store.root, to: root.appendingPathComponent("b"))
    let localB = LocalStore(dir: root.appendingPathComponent("local-b"))
    _ = try Kagi.recover(at: root.appendingPathComponent("b"), recoveryKey: pending.recoveryKey,
      deviceName: "B", backend: backend, local: localB, reason: { $0 })
    b = try Session(local: localB, backend: backend)
    remote = try DirectorySyncTransport(root: root.appendingPathComponent("remote"))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func sync(_ session: Session, choices: [String: SyncChoice] = [:]) throws -> SyncResult {
    try session.synchronize(with: remote, key: key, resolutions: choices)
  }
  func pair() throws { _ = try sync(a); _ = try sync(b); _ = try sync(a) }
  @discardableResult func put(_ s: Session, _ ref: String, _ text: String) throws -> Listing {
    let ref = try Ref(ref)
    _ = try s.write(ref: ref, value: Data(text.utf8), issuer: nil, usedIn: nil,
      existing: s.find(ref), key: key)
    return try XCTUnwrap(s.find(ref))
  }
  func read(_ s: Session, _ ref: String) throws -> String {
    let item = try XCTUnwrap(s.find(Ref(ref)))
    return String(decoding: try s.read(item, key: key).value, as: UTF8.self)
  }
  func testIndependentKeysConvergeAndNoOpHasStableHead() throws {
    try pair()
    try put(a, "a/token", "FAKE-A")
    try put(b, "b/token", "FAKE-B")
    _ = try sync(a); _ = try sync(b); _ = try sync(a)
    XCTAssertEqual(try read(a, "b/token"), "FAKE-B")
    XCTAssertEqual(try read(b, "a/token"), "FAKE-A")
    let head = try remote.head()
    _ = try sync(a); _ = try sync(b)
    XCTAssertEqual(try remote.head(), head)
    XCTAssertEqual(try a.store.devices().count, 2)
  }
  func testSameVersionDivergencePreservesBothAndRequiresExplicitDecision() throws {
    try put(a, "service/key", "FAKE-BASE")
    try pair()
    try put(a, "service/key", "FAKE-A")
    try put(b, "service/key", "FAKE-B")
    _ = try sync(a)
    let result = try sync(b)
    XCTAssertEqual(result.conflicts.map(\.item), ["key:service/key"])
    XCTAssertEqual(result.conflicts[0].local.keys.first?.latestVersion, 2)
    XCTAssertEqual(result.conflicts[0].remote.keys.first?.latestVersion, 2)
    XCTAssertEqual(result.conflicts[0].base.keys.first?.latestVersion, 1)
    XCTAssertEqual(try read(b, "service/key"), "FAKE-B")
    XCTAssertEqual(try sync(b).conflicts, result.conflicts)
    let files = try FileManager.default.contentsOfDirectory(atPath: remote.root.appendingPathComponent("objects").path)
    XCTAssertGreaterThan(files.count, 4)
    _ = try sync(b, choices: [result.conflicts[0].id: .local]); _ = try sync(a)
    XCTAssertEqual(try read(a, "service/key"), "FAKE-B")
    XCTAssertTrue(try sync(a).conflicts.isEmpty)
  }
  func testDuplicateRefCreatedOfflineIsOneConflictAndRemoteChoiceWorks() throws {
    try pair()
    try put(a, "same/ref", "FAKE-A"); try put(b, "same/ref", "FAKE-B")
    _ = try sync(a)
    let result = try sync(b)
    XCTAssertEqual(result.conflicts.count, 1)
    _ = try sync(b, choices: [result.conflicts[0].id: .remote])
    XCTAssertEqual(try read(b, "same/ref"), "FAKE-A")
    XCTAssertEqual(try b.listings().count, 1)
    let resolvedHead = try XCTUnwrap(remote.head())
    let resolvedArchive = try JSONDecoder().decode(SyncArchive.self, from: remote.object(resolvedHead))
    XCTAssertEqual(try resolvedArchive.open(key: key).parents.count, 2)
  }
  func testStaleConflictChoiceRejectedWithoutApplying() throws {
    try pair(); try put(a, "same/ref", "FAKE-A"); try put(b, "same/ref", "FAKE-B")
    _ = try sync(a)
    let id = try sync(b).conflicts[0].id
    try put(a, "same/ref", "FAKE-A2"); _ = try sync(a)
    XCTAssertThrowsError(try sync(b, choices: [id: .remote]))
    XCTAssertEqual(try read(b, "same/ref"), "FAKE-B")
  }
  func testSpacesMergeIndependentlyAndSameSpaceRenameConflicts() throws {
    try pair()
    try a.createSpace(id: "work", name: "工作", key: key)
    try b.createSpace(id: "home", name: "家庭", key: key)
    _ = try sync(a); _ = try sync(b); _ = try sync(a)
    XCTAssertEqual(Set(try a.spaces().map(\.id)), ["default", "work", "home"])
    try a.renameSpace(id: "work", name: "A", key: key)
    try b.renameSpace(id: "work", name: "B", key: key)
    _ = try sync(a)
    XCTAssertEqual(try sync(b).conflicts.map(\.item), ["space:work"])
  }
  func testArchiveAndRotationConflictCannotSilentlyReactivate() throws {
    try put(a, "api/key", "FAKE-BASE"); try pair()
    let item = try XCTUnwrap(a.find(Ref("api/key")))
    var metadata = item.record.metadata; metadata.archived = true
    try a.updateKey(item, metadata: metadata, issuer: nil, usedIn: nil, key: key)
    try put(b, "api/key", "FAKE-ROTATED"); _ = try sync(a)
    let result = try sync(b)
    XCTAssertEqual(result.conflicts.count, 1)
    _ = try sync(b, choices: [result.conflicts[0].id: .remote])
    XCTAssertNil(try b.find(Ref("api/key")))
    XCTAssertEqual(try b.listings(includeArchived: true).count, 1)
  }
  func testTypedCredentialsSurviveSyncAndStayProtected() throws {
    try pair()
    let otp = try TOTPCredential.parse("JBSWY3DPEHPK3PXP")
    _ = try a.importTOTP(ref: Ref("otp/test"), credential: otp, key: key)
    _ = try sync(a); _ = try sync(b)
    let item = try XCTUnwrap(b.find(Ref("otp/test")))
    XCTAssertEqual(try b.totpCode(item, at: 59, key: key), try otp.code(at: 59))
    XCTAssertThrowsError(try b.read(item, key: key))
  }
  func testTamperedObjectAndHistoryRollbackRejected() throws {
    try pair()
    let old = try XCTUnwrap(remote.head())
    try put(a, "api/key", "FAKE-A"); _ = try sync(a); _ = try sync(b)
    let current = try XCTUnwrap(remote.head())
    XCTAssertTrue(try remote.compareAndSwap(expected: current, replacement: old))
    XCTAssertThrowsError(try sync(b))
    XCTAssertTrue(try remote.compareAndSwap(expected: old, replacement: current))
    try Data("TAMPER".utf8).write(to: remote.root.appendingPathComponent("objects/" + current))
    XCTAssertThrowsError(try sync(b))
    XCTAssertEqual(try read(b, "api/key"), "FAKE-A")
  }
  func testCASRaceLeavesLocalAndBaselineUnchanged() throws {
    try pair()
    try put(a, "api/key", "FAKE-A"); _ = try sync(a)
    let before = try Data(contentsOf: b.store.root.appendingPathComponent(".sync-state"))
    struct Racing: SyncTransport {
      let inner: DirectorySyncTransport
      var identity: String { inner.identity }
      func head() throws -> String? { try inner.head() }
      func object(_ id: String) throws -> Data { try inner.object(id) }
      func put(_ data: Data) throws -> String { try inner.put(data) }
      func compareAndSwap(expected: String?, replacement: String) throws -> Bool { false }
    }
    XCTAssertThrowsError(try b.synchronize(with: Racing(inner: remote), key: key))
    XCTAssertNil(try b.find(Ref("api/key")))
    XCTAssertEqual(try Data(contentsOf: b.store.root.appendingPathComponent(".sync-state")), before)
    _ = try sync(b)
    XCTAssertEqual(try read(b, "api/key"), "FAKE-A")
  }
  func testPendingInstallBlocksOperationsAndReplaysAfterPartialWrite() throws {
    try pair(); try put(a, "api/key", "FAKE-A"); _ = try sync(a)
    let revision = try XCTUnwrap(remote.head())
    let archive = try JSONDecoder().decode(SyncArchive.self, from: remote.object(revision))
    let snapshot = try archive.open(key: key)
    struct Pending: Codable { let transport: String; let revision: String; let snapshot: SyncSnapshot }
    let pending = Pending(transport: remote.identity, revision: revision, snapshot: snapshot)
    let sealed = try Crypto.seal(try JSON.encode(pending), key: key,
      binding: Data("kagi-sync-local/1|\(a.vault.vault)|pending".utf8))
    try Data(sealed.utf8).write(to: b.store.root.appendingPathComponent(".sync-pending"))
    let path = try XCTUnwrap(snapshot.files.keys.first { $0.hasPrefix("index/") })
    try SyncIO.write(snapshot.files[path]!, to: b.store.root.appendingPathComponent(path))
    XCTAssertThrowsError(try b.listings())
    XCTAssertThrowsError(try b.createSpace(id: "blocked", name: "blocked", key: key))
    b = try Session(local: LocalStore(dir: root.appendingPathComponent("local-b")), backend: backend)
    let result = try sync(b)
    XCTAssertTrue(result.recovered)
    XCTAssertEqual(try read(b, "api/key"), "FAKE-A")
    XCTAssertFalse(FileManager.default.fileExists(atPath: b.store.root.appendingPathComponent(".sync-pending").path))
  }
  func testNewDeviceBootstrapsFromRemoteWithRecoveryKeyOnly() throws {
    try put(a, "api/key", "FAKE-REMOTE-BOOTSTRAP"); _ = try sync(a)
    let localC = LocalStore(dir: root.appendingPathComponent("local-c"))
    let destination = root.appendingPathComponent("c")
    _ = try Kagi.recoverFromSync(with: remote, at: destination, recoveryKey: recoveryKey,
      deviceName: "C", backend: backend, local: localC, reason: { $0 })
    let c = try Session(local: localC, backend: backend)
    XCTAssertNotEqual(c.state.device, a.state.device)
    XCTAssertEqual(try read(c, "api/key"), "FAKE-REMOTE-BOOTSTRAP")
    _ = try sync(c); _ = try sync(a)
    XCTAssertTrue(try a.store.devices().contains { $0.device == c.state.device })
    let bad = root.appendingPathComponent("bad-join")
    XCTAssertThrowsError(try Kagi.recoverFromSync(with: remote, at: bad,
      recoveryKey: RecoveryKey.generate(), deviceName: "Bad", backend: backend,
      local: LocalStore(dir: root.appendingPathComponent("local-bad")), reason: { $0 }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
  }
  func testSpaceRemovalVersusOfflineNewKeyRequiresDependencyDecision() throws {
    try a.createSpace(id: "work", name: "Work", key: key); try pair()
    try a.removeSpace(id: "work", key: key)
    let item = try put(b, "work/new", "FAKE-NEW")
    var metadata = item.record.metadata; metadata.space = "work"
    try b.updateKey(item, metadata: metadata, issuer: nil, usedIn: nil, key: key)
    _ = try sync(a)
    let result = try sync(b)
    XCTAssertEqual(result.conflicts.map(\.item), ["space-use:work"])
    _ = try sync(b, choices: [result.conflicts[0].id: .local]); _ = try sync(a)
    XCTAssertEqual(try read(a, "work/new"), "FAKE-NEW")
    XCTAssertTrue(try a.spaces().contains { $0.id == "work" })
  }
  func testNearLimitReplicaCanReplaceConflictingEntryWithoutCountingBothSnapshots() throws {
    try pair()
    // Each snapshot fits 32 MiB, but both entry IDs coexist briefly during install.
    try put(a, "same/ref", String(repeating: "A", count: 2 * 1024 * 1024))
    try put(b, "same/ref", String(repeating: "B", count: 17 * 1024 * 1024))
    _ = try sync(a)
    let conflict = try XCTUnwrap(sync(b).conflicts.first)
    let result = try sync(b, choices: [conflict.id: .remote])
    XCTAssertTrue(result.conflicts.isEmpty)
    XCTAssertEqual(try b.store.entryIDs().count, 1)
    XCTAssertEqual(try read(b, "same/ref").count, 2 * 1024 * 1024)
    XCTAssertFalse(FileManager.default.fileExists(atPath: b.store.root.appendingPathComponent(".sync-pending").path))
  }
  func testDependencyDecisionCannotOverrideExplicitKeyDecision() throws {
    try a.createSpace(id: "work", name: "Work", key: key)
    try put(a, "api/key", "FAKE-BASE"); try pair()
    try a.removeSpace(id: "work", key: key)
    try put(a, "api/key", "FAKE-A")
    let item = try put(b, "api/key", "FAKE-B")
    var metadata = item.record.metadata; metadata.space = "work"
    try b.updateKey(item, metadata: metadata, issuer: nil, usedIn: nil, key: key)
    _ = try sync(a)
    let keyConflict = try XCTUnwrap(sync(b).conflicts.first)
    let dependency = try XCTUnwrap(sync(b, choices: [keyConflict.id: .local]).conflicts.first)
    XCTAssertEqual(dependency.item, "space-use:work")
    let head = try remote.head()
    XCTAssertThrowsError(try sync(b, choices: [keyConflict.id: .local, dependency.id: .remote]))
    XCTAssertEqual(try read(b, "api/key"), "FAKE-B")
    XCTAssertEqual(try remote.head(), head)
  }
  func testSameTimestampAndVersionCannotReuseApprovalAfterConflictResolution() throws {
    try put(a, "api/key", "FAKE-BASE"); try pair()
    let remoteItem = try put(a, "api/key", "FAKE-A")
    let localItem = try put(b, "api/key", "FAKE-B")
    // Reproduce same-second writes deterministically, including identical management fields.
    try b.saveIndex(entry: localItem.entry, record: remoteItem.record)
    let stale = try XCTUnwrap(b.find(Ref("api/key")))
    _ = try sync(a)
    let conflict = try XCTUnwrap(sync(b).conflicts.first)
    _ = try sync(b, choices: [conflict.id: .remote])
    XCTAssertEqual(try b.find(Ref("api/key"))?.record, stale.record)
    XCTAssertThrowsError(try b.read(stale, key: key))
    XCTAssertThrowsError(try b.write(ref: Ref("api/key"), value: Data("FAKE-STALE".utf8),
      issuer: nil, usedIn: nil, existing: stale, key: key))
    XCTAssertEqual(try read(b, "api/key"), "FAKE-A")
  }
  func testIndexRewriteWithSameMetadataInvalidatesManagementSnapshot() throws {
    let stale = try put(a, "api/key", "FAKE-BASE")
    try a.saveIndex(entry: stale.entry, record: stale.record)
    var metadata = stale.record.metadata; metadata.tags = ["stale"]
    XCTAssertThrowsError(try a.updateKey(stale, metadata: metadata, issuer: nil, usedIn: nil, key: key))
    XCTAssertEqual(try a.find(Ref("api/key"))?.record.metadata.tags, [])
  }
  func testDiscardedEntryWithInterruptedWriteDoesNotRemainInActiveInventory() throws {
    try pair()
    try put(a, "same/ref", "FAKE-A")
    let old = try put(b, "same/ref", "FAKE-B")
    let interrupted = b.store.entriesDir.appendingPathComponent(old.entry).appendingPathComponent(".pending-interrupted")
    let bytes = Data("FAKE-UNPUBLISHED-CIPHERTEXT".utf8)
    try bytes.write(to: interrupted)
    _ = try sync(a)
    let conflict = try XCTUnwrap(sync(b).conflicts.first)
    _ = try sync(b, choices: [conflict.id: .remote])
    XCTAssertEqual(try b.listings().count, 1)
    XCTAssertEqual(try read(b, "same/ref"), "FAKE-A")
    let retiredRoot = b.store.root.appendingPathComponent(".sync-retired")
    let retired = try XCTUnwrap(FileManager.default.enumerator(at: retiredRoot,
      includingPropertiesForKeys: nil)?.allObjects as? [URL])
    let saved = try XCTUnwrap(retired.first { $0.lastPathComponent == ".pending-interrupted" })
    XCTAssertEqual(try Data(contentsOf: saved), bytes)
  }
  func testAuthenticatedMaliciousSnapshotPathsAreStillRejected() throws {
    try pair()
    let head = try XCTUnwrap(remote.head())
    let archive = try JSONDecoder().decode(SyncArchive.self, from: remote.object(head))
    var snapshot = try archive.open(key: key)
    snapshot.parents = [head]
    snapshot.files["../outside"] = Data("FAKE-ESCAPE".utf8)
    let malicious = try remote.put(SyncArchive.seal(snapshot, key: key))
    XCTAssertTrue(try remote.compareAndSwap(expected: head, replacement: malicious))
    XCTAssertThrowsError(try sync(a))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
  }
  func testPasskeyPrivateMaterialAndIdentitySurviveSync() throws {
    try pair()
    let request = PasskeyRequest(rpID: "example.test", origin: "https://example.test",
      challenge: Base64URL.encode(Data(repeating: 1, count: 32)),
      userHandle: Base64URL.encode(Data("FAKE-USER".utf8)), userName: "Fake")
    let registration = try a.registerPasskey(ref: Ref("passkey/test"), request: request, key: key)
    let before = try a.read(XCTUnwrap(a.find(Ref("passkey/test"))), key: key, kind: .passkey).value
    _ = try sync(a); _ = try sync(b)
    let item = try XCTUnwrap(b.find(Ref("passkey/test")))
    XCTAssertEqual(try b.read(item, key: key, kind: .passkey).value, before)
    XCTAssertThrowsError(try b.read(item, key: key))
    let assertion = try b.assertPasskey(item, request: PasskeyRequest(
      rpID: request.rpID, origin: request.origin, challenge: request.challenge), key: key)
    XCTAssertEqual(assertion.id, registration.id)
  }
  func testArchiveHeaderTamperAndFailedUploadCannotAdvanceState() throws {
    try pair()
    let head = try XCTUnwrap(remote.head())
    var archive = try JSONDecoder().decode(SyncArchive.self, from: remote.object(head))
    archive.vault.created = "TAMPER"
    let tampered = try remote.put(JSON.encode(archive))
    XCTAssertTrue(try remote.compareAndSwap(expected: head, replacement: tampered))
    XCTAssertThrowsError(try sync(a))
    XCTAssertTrue(try remote.compareAndSwap(expected: tampered, replacement: head))
    try put(a, "api/key", "FAKE-UPLOAD")
    let baseline = try Data(contentsOf: a.store.root.appendingPathComponent(".sync-state"))
    struct Failing: SyncTransport {
      let inner: DirectorySyncTransport
      var identity: String { inner.identity }
      func head() throws -> String? { try inner.head() }
      func object(_ id: String) throws -> Data { try inner.object(id) }
      func put(_ data: Data) throws -> String { throw KagiError(.tempFail, "FAKE upload failure") }
      func compareAndSwap(expected: String?, replacement: String) throws -> Bool { false }
    }
    XCTAssertThrowsError(try a.synchronize(with: Failing(inner: remote), key: key))
    XCTAssertEqual(try Data(contentsOf: a.store.root.appendingPathComponent(".sync-state")), baseline)
    XCTAssertEqual(try read(a, "api/key"), "FAKE-UPLOAD")
    XCTAssertEqual(try remote.head(), head)
  }
  func testUnsafePathsAndSymlinksRejected() throws {
    let url = a.store.root.appendingPathComponent("keys/evil.json")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("local-a/device.json"))
    XCTAssertThrowsError(try sync(a))
    XCTAssertNil(try remote.head())
    XCTAssertThrowsError(try remote.object("../outside"))
  }
  func testEncryptedSnapshotsDoNotExposeRefsSeedsOrDeviceBlobs() throws {
    try put(a, "private/fake-ref", "FAKE-PLAINTEXT-SECRET")
    _ = try sync(a)
    let id = try XCTUnwrap(remote.head())
    let bytes = try remote.object(id)
    let text = String(decoding: bytes, as: UTF8.self)
    XCTAssertFalse(text.contains("fake-ref")); XCTAssertFalse(text.contains("FAKE-PLAINTEXT-SECRET"))
    XCTAssertFalse(text.contains(a.state.secretKeyBlob))
    let archive = try JSONDecoder().decode(SyncArchive.self, from: bytes)
    let snapshot = try archive.open(key: key)
    XCTAssertFalse(snapshot.files.keys.contains { $0.hasPrefix(".") || $0.contains("device.json") })
  }
}
