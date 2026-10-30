import CryptoKit
import Foundation
import XCTest

@testable import KagiCore

/// 只用明显的假值。设备密钥用软件密钥代替 Secure Enclave，指纹框用 SoftwareBackend.decision 模拟。
final class VaultTests: XCTestCase {
  var temp: URL!
  var vaultRoot: URL { temp.appendingPathComponent("vault", isDirectory: true) }
  var local: LocalStore { LocalStore(dir: temp.appendingPathComponent("local", isDirectory: true)) }

  override func setUpWithError() throws {
    temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kagi-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temp)
  }

  func makeVault(_ backend: SoftwareBackend = SoftwareBackend()) throws -> PendingVault {
    let pending = try Kagi.prepareInit(
      at: vaultRoot, deviceName: "测试 Mac", backend: backend, reason: { "确认（新建库 \($0)）" })
    try pending.commit(local: local)
    return pending
  }

  func testStoreAndReadBack() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let session = try Session(local: local, backend: backend)
    let ref = try Ref("demo/fake-token")
    let key = try session.unlock(reason: "存入", action: .write, byAgent: false)
    let version = try session.write(
      ref: ref, value: Data("FAKE-VALUE-0001-not-a-secret".utf8), issuer: "Demo", usedIn: "测试",
      existing: nil, key: key)
    XCTAssertEqual(version, 1)

    let listing = try XCTUnwrap(session.find(ref))
    XCTAssertEqual(listing.record.issuer, "Demo")
    XCTAssertEqual(listing.record.usedIn, "测试")
    let read = try session.read(listing, key: key)
    XCTAssertEqual(read.version, 1)
    XCTAssertEqual(String(decoding: read.value, as: UTF8.self), "FAKE-VALUE-0001-not-a-secret")
  }

  func testOverwriteKeepsOldVersionAndMetadata() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let session = try Session(local: local, backend: backend)
    let ref = try Ref("demo/fake-token")
    let key = try session.unlock(reason: "存入", action: .write, byAgent: false)
    try session.write(
      ref: ref, value: Data("FAKE-VALUE-0001".utf8), issuer: "Demo", usedIn: nil, existing: nil,
      key: key)
    let first = try XCTUnwrap(session.find(ref))
    try session.write(
      ref: ref, value: Data("FAKE-VALUE-0002".utf8), issuer: nil, usedIn: nil, existing: first,
      key: key)

    let second = try XCTUnwrap(session.find(ref))
    XCTAssertEqual(second.entry, first.entry)
    XCTAssertEqual(second.record.latestVersion, 2)
    XCTAssertEqual(second.record.issuer, "Demo", "覆盖时没给的元数据沿用旧的")
    XCTAssertEqual(try session.store.versions(of: second.entry), [1, 2])
    XCTAssertEqual(
      String(decoding: try session.read(second, key: key).value, as: UTF8.self), "FAKE-VALUE-0002")
  }

  func testDeniedAndLockedPromptsHandOutNothing() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let session = try Session(local: local, backend: backend)

    backend.decision = .deny
    XCTAssertThrowsError(try session.unlock(reason: "交出", action: .read, byAgent: true)) { error in
      let error = error as? KagiError
      XCTAssertEqual(error?.code, .denied)
      XCTAssertEqual(error?.hint, "请停下来问用户怎么做，不要换一种方式重试。")
    }
    backend.decision = .locked
    XCTAssertThrowsError(try session.unlock(reason: "交出", action: .read, byAgent: true)) { error in
      XCTAssertEqual((error as? KagiError)?.code, .tempFail)
    }
  }

  func testInitIsCancelledWhenThePromptIsDenied() throws {
    let backend = SoftwareBackend(decision: .deny)
    XCTAssertThrowsError(try makeVault(backend)) { error in
      XCTAssertEqual((error as? KagiError)?.code, .denied)
    }
    XCTAssertFalse(VaultStore(root: vaultRoot).exists, "取消时不能留下半个库")
  }

  func testListingNamesNeedsNoPrompt() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let session = try Session(local: local, backend: backend)
    let key = try session.unlock(reason: "存入", action: .write, byAgent: false)
    try session.write(
      ref: try Ref("b/two"), value: Data("FAKE-VALUE-B".utf8), issuer: nil, usedIn: nil,
      existing: nil, key: key)
    try session.write(
      ref: try Ref("a/one"), value: Data("FAKE-VALUE-A".utf8), issuer: nil, usedIn: nil,
      existing: nil, key: key)
    let promptsBefore = backend.prompts.count

    let fresh = try Session(local: local, backend: backend)
    XCTAssertEqual(try fresh.listings().map(\.ref), ["a/one", "b/two"])
    XCTAssertEqual(backend.prompts.count, promptsBefore, "列名字不弹框")
  }

  func testLockedMetadataReadFailsWithoutPrompting() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let promptsBefore = backend.prompts.count
    backend.decision = .locked
    let session = try Session(local: local, backend: backend)
    XCTAssertThrowsError(try session.listings()) { error in
      XCTAssertEqual((error as? KagiError)?.code, .tempFail)
    }
    XCTAssertEqual(backend.prompts.count, promptsBefore)
  }

  func testTamperedEntryIsRejected() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let session = try Session(local: local, backend: backend)
    let ref = try Ref("demo/fake-token")
    let key = try session.unlock(reason: "存入", action: .write, byAgent: false)
    try session.write(
      ref: ref, value: Data("FAKE-VALUE-0001".utf8), issuer: nil, usedIn: nil, existing: nil,
      key: key)
    let listing = try XCTUnwrap(session.find(ref))

    // 改密文里的一个字节。
    let url = session.store.entryURL(listing.entry, 1)
    var file = try JSONDecoder().decode(EntryFile.self, from: Data(contentsOf: url))
    var box = try XCTUnwrap(Data(base64Encoded: file.box))
    box[box.count - 20] ^= 0x01
    file.box = box.base64EncodedString()
    try JSONEncoder().encode(file).write(to: url)

    XCTAssertThrowsError(try session.read(listing, key: key)) { error in
      XCTAssertEqual((error as? KagiError)?.code, .dataError)
    }
  }

  func testSwappedEntriesAreRejected() throws {
    let backend = SoftwareBackend()
    _ = try makeVault(backend)
    let session = try Session(local: local, backend: backend)
    let key = try session.unlock(reason: "存入", action: .write, byAgent: false)
    try session.write(
      ref: try Ref("demo/one"), value: Data("FAKE-VALUE-ONE".utf8), issuer: nil, usedIn: nil,
      existing: nil, key: key)
    try session.write(
      ref: try Ref("demo/two"), value: Data("FAKE-VALUE-TWO".utf8), issuer: nil, usedIn: nil,
      existing: nil, key: key)
    let one = try XCTUnwrap(session.find(try Ref("demo/one")))
    let two = try XCTUnwrap(session.find(try Ref("demo/two")))

    // 把第二条的密文挪到第一条的位置，连 JSON 里的 entry 字段一起改。
    let oneURL = session.store.entryURL(one.entry, 1)
    var moved = try JSONDecoder().decode(
      EntryFile.self, from: Data(contentsOf: session.store.entryURL(two.entry, 1)))
    moved.entry = one.entry
    try JSONEncoder().encode(moved).write(to: oneURL)

    XCTAssertThrowsError(try session.read(one, key: key)) { error in
      XCTAssertEqual((error as? KagiError)?.code, .dataError)
    }
  }

  func testSwappedDeviceWrapIsCaughtByThePinnedCheck() throws {
    let backend = SoftwareBackend()
    let pending = try makeVault(backend)
    let state = try XCTUnwrap(try local.load())

    // 网盘上的人用这台 Mac 的公钥包了一把自己的库密钥，并把 vault.json 的校验值一起换掉。
    let attackerKey = Crypto.newKey()
    var device = pending.device
    device.secretWrap = try Crypto.hpkeSeal(
      Crypto.keyData(attackerKey), to: try Crypto.publicKey(from: device.secretPublicKey),
      binding: Binding.device(vault: pending.vault.vault, device: device.device, purpose: .secret))
    try VaultStore(root: vaultRoot).writeDevice(device)
    var vault = pending.vault
    vault.keyCheck = Crypto.keyCheck(attackerKey, vault: vault.vault, purpose: .secret)
    try JSON.encode(vault).write(to: VaultStore(root: vaultRoot).vaultURL)

    XCTAssertThrowsError(try Session(local: local, backend: backend)) { error in
      XCTAssertEqual((error as? KagiError)?.code, .dataError)
    }
    XCTAssertEqual(state.keyCheck, pending.vault.keyCheck)
  }

  func testRecoverOnAnotherMac() throws {
    let backend = SoftwareBackend()
    let pending = try makeVault(backend)
    let session = try Session(local: local, backend: backend)
    let key = try session.unlock(reason: "存入", action: .write, byAgent: false)
    try session.write(
      ref: try Ref("demo/fake-token"), value: Data("FAKE-VALUE-0001".utf8), issuer: nil,
      usedIn: nil, existing: nil, key: key)

    let otherLocal = LocalStore(dir: temp.appendingPathComponent("other-mac", isDirectory: true))
    let typed = pending.recoveryKey.displayText.lowercased().replacingOccurrences(
      of: "-", with: " ")
    let (_, device) = try Kagi.recover(
      at: vaultRoot, recoveryKey: try RecoveryKey(parsing: typed), deviceName: "新 Mac",
      backend: backend,
      local: otherLocal, reason: { "加入 \($0)" })
    XCTAssertNotEqual(device.device, pending.device.device)

    let other = try Session(local: otherLocal, backend: backend)
    let otherKey = try other.unlock(reason: "交出", action: .read, byAgent: false)
    let listing = try XCTUnwrap(other.find(try Ref("demo/fake-token")))
    XCTAssertEqual(
      String(decoding: try other.read(listing, key: otherKey).value, as: UTF8.self),
      "FAKE-VALUE-0001")
    XCTAssertEqual(try other.devices().count, 2)
  }

  func testWrongRecoveryKeyIsRejected() throws {
    _ = try makeVault()
    let otherLocal = LocalStore(dir: temp.appendingPathComponent("other-mac", isDirectory: true))
    XCTAssertThrowsError(
      try Kagi.recover(
        at: vaultRoot, recoveryKey: RecoveryKey.generate(), deviceName: "新 Mac",
        backend: SoftwareBackend(),
        local: otherLocal, reason: { $0 })
    ) { error in
      XCTAssertEqual((error as? KagiError)?.code, .dataError)
    }
    XCTAssertNil(try otherLocal.load())
  }
  func testPublishingSameVersionNeverOverwritesIt() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    try session.write(
      ref: Ref("demo/token"), value: Data("FAKE-ORIGINAL".utf8), issuer: nil, usedIn: nil,
      existing: nil, key: key)
    let listing = try XCTUnwrap(session.find(Ref("demo/token")))
    var file = try session.store.readEntry(listing.entry, version: 1)
    let original = try Data(contentsOf: session.store.entryURL(listing.entry, 1))
    file.box = "replacement"
    XCTAssertThrowsError(try session.store.writeEntry(file))
    XCTAssertEqual(try Data(contentsOf: session.store.entryURL(listing.entry, 1)), original)
  }

  func testStaleCreationAndUpdateAreRejected() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    let ref = try Ref("demo/token")
    try session.write(
      ref: ref, value: Data("FAKE-ONE".utf8), issuer: nil, usedIn: nil, existing: nil, key: key)
    XCTAssertThrowsError(
      try session.write(
        ref: ref, value: Data("FAKE-TWO".utf8), issuer: nil, usedIn: nil, existing: nil, key: key))
    let first = try XCTUnwrap(session.find(ref))
    try session.write(
      ref: ref, value: Data("FAKE-TWO".utf8), issuer: nil, usedIn: nil, existing: first, key: key)
    XCTAssertThrowsError(
      try session.write(
        ref: ref, value: Data("FAKE-THREE".utf8), issuer: nil, usedIn: nil, existing: first,
        key: key))
    XCTAssertEqual(try session.store.versions(of: first.entry), [1, 2])
  }

  func testMissingIndexIsDetectedAndRepairedFromAuthenticatedEntry() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    let ref = try Ref("demo/token")
    try session.write(
      ref: ref, value: Data("FAKE-ONE".utf8), issuer: "Demo", usedIn: nil, existing: nil, key: key)
    let item = try XCTUnwrap(session.find(ref))
    try FileManager.default.removeItem(
      at: session.store.indexDir.appendingPathComponent(item.entry + ".kagi"))
    XCTAssertThrowsError(try session.listings())
    XCTAssertEqual(try session.repairIndex(key: key), 1)
    let restored = try XCTUnwrap(session.find(ref, includeArchived: true))
    XCTAssertNil(restored.record.issuer)
    XCTAssertTrue(restored.record.metadata.archived)
    var metadata = restored.record.metadata
    metadata.archived = false
    try session.updateKey(restored, metadata: metadata, issuer: nil, usedIn: nil, key: key)
    XCTAssertEqual(
      try session.read(XCTUnwrap(session.find(ref)), key: key).value, Data("FAKE-ONE".utf8))
  }

  func testRepairUpdatesStaleIndexButRefusesMissingNewVersion() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    let ref = try Ref("demo/token")
    try session.write(
      ref: ref, value: Data("FAKE-ONE".utf8), issuer: "Demo", usedIn: "Tests", existing: nil,
      key: key)
    let first = try XCTUnwrap(session.find(ref))
    let indexURL = session.store.indexDir.appendingPathComponent(first.entry + ".kagi")
    let oldIndex = try Data(contentsOf: indexURL)
    try session.write(
      ref: ref, value: Data("FAKE-TWO".utf8), issuer: nil, usedIn: nil, existing: first, key: key)
    try oldIndex.write(to: indexURL)
    XCTAssertThrowsError(try session.listings())
    XCTAssertEqual(try session.repairIndex(key: key), 1)
    let repaired = try XCTUnwrap(session.find(ref))
    XCTAssertEqual(repaired.record.latestVersion, 2)
    XCTAssertEqual(repaired.record.issuer, "Demo")
    let repairedIndex = try Data(contentsOf: indexURL)
    try FileManager.default.removeItem(at: session.store.entryURL(first.entry, 2))
    XCTAssertThrowsError(try session.repairIndex(key: key))
    XCTAssertEqual(try Data(contentsOf: indexURL), repairedIndex)
  }

  func testConflictingVersionFilenameIsNotSilentlyIgnored() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    try session.write(
      ref: Ref("demo/token"), value: Data("FAKE-ONE".utf8), issuer: nil, usedIn: nil, existing: nil,
      key: key)
    let item = try XCTUnwrap(session.find(Ref("demo/token")))
    let conflict = session.store.entryURL(item.entry, 1).deletingLastPathComponent()
      .appendingPathComponent("0001 (conflict).kagi")
    try Data("conflict".utf8).write(to: conflict)
    XCTAssertThrowsError(try session.listings())
    XCTAssertThrowsError(try session.repairIndex(key: key))
  }

  func testDuplicateReferencesFailInsteadOfChoosingOne() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    try session.write(
      ref: Ref("demo/token"), value: Data("FAKE-ONE".utf8), issuer: nil, usedIn: nil, existing: nil,
      key: key)
    let item = try XCTUnwrap(session.find(Ref("demo/token")))
    let other = Base32.encode(Crypto.randomBytes(10)).lowercased()
    try session.store.writeIndex(
      IndexFile(
        format: Format.index, vault: session.vault.vault, entry: other,
        box: Crypto.seal(
          JSON.encode(item.record), key: session.indexKey(),
          binding: Binding.index(vault: session.vault.vault, entry: other))))
    XCTAssertThrowsError(try session.listings())
    XCTAssertThrowsError(try session.repairIndex(key: key))
  }

  func testRepairAuthenticatesAllEntriesBeforeWritingAnyIndex() throws {
    _ = try makeVault()
    let session = try Session(local: local, backend: SoftwareBackend())
    let key = try session.unlock(reason: "测试", action: .write, byAgent: false)
    for ref in ["demo/one", "demo/two"] {
      try session.write(
        ref: Ref(ref), value: Data("FAKE-VALUE".utf8), issuer: nil, usedIn: nil, existing: nil,
        key: key)
    }
    let ids = try session.store.entryIDs()
    for id in ids {
      try FileManager.default.removeItem(
        at: session.store.indexDir.appendingPathComponent(id + ".kagi"))
    }
    // 最后一个条目损坏；前面的条目即便可恢复，也不应先写出索引。
    try Data("corrupt".utf8).write(to: session.store.entryURL(ids.last!, 1))
    XCTAssertThrowsError(try session.repairIndex(key: key))
    XCTAssertTrue(try session.store.indexFiles().isEmpty)
  }

}
