import CryptoKit
import Foundation
import XCTest

@testable import KagiCore

final class ManagementTests: XCTestCase {
  var root: URL!
  var backend: SoftwareBackend!
  var session: Session!
  var key: SymmetricKey!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kagi-management-\(UUID().uuidString)")
    backend = SoftwareBackend()
    let local = LocalStore(dir: root.appendingPathComponent("local"))
    let pending = try Kagi.prepareInit(
      at: root.appendingPathComponent("vault"), deviceName: "Test",
      backend: backend, reason: { $0 })
    try pending.commit(local: local)
    session = try Session(local: local, backend: backend)
    key = try session.unlock(reason: "FAKE management", action: .write, byAgent: false)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  @discardableResult
  func put(_ ref: String = "demo/token", metadata: KeyMetadata? = nil) throws -> Listing {
    try session.write(
      ref: Ref(ref), value: Data("FAKE-MANAGEMENT-SECRET".utf8), issuer: "Demo", usedIn: "Tests",
      existing: nil, key: key, metadata: metadata)
    return try XCTUnwrap(session.find(Ref(ref)))
  }

  func update(_ item: Listing, _ metadata: KeyMetadata) throws {
    try session.updateKey(
      item, metadata: metadata, issuer: item.record.issuer, usedIn: item.record.usedIn, key: key)
  }

  func testSpaceCRUDAndProtectedDefault() throws {
    XCTAssertEqual(try session.spaces().map(\.id), ["default"])
    try session.createSpace(id: "work", name: "工作", key: key)
    try session.renameSpace(id: "work", name: "团队项目", key: key)
    XCTAssertEqual(try session.spaces().first { $0.id == "work" }?.name, "团队项目")
    XCTAssertThrowsError(try session.createSpace(id: "work", name: "Duplicate", key: key))
    XCTAssertThrowsError(try session.createSpace(id: "bad/id", name: "Invalid", key: key))
    XCTAssertThrowsError(try session.removeSpace(id: "default", key: key))
    try session.removeSpace(id: "work", key: key)
    XCTAssertEqual(try session.spaces().map(\.id), ["default"])
  }

  func testMoveAndTitleEditPreserveRefValueAndVersionBytes() throws {
    let item = try put()
    let url = session.store.entryURL(item.entry, 1)
    let before = try Data(contentsOf: url)
    try session.createSpace(id: "work", name: "工作", key: key)
    try update(item, KeyMetadata(title: "生产 API", space: "work", tags: ["Prod", "prod", " api "]))
    let after = try XCTUnwrap(session.find(Ref(item.ref)))
    XCTAssertEqual(after.entry, item.entry)
    XCTAssertEqual(after.ref, "demo/token")
    XCTAssertEqual(after.record.metadata.tags, ["api", "prod"])
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertEqual(try session.store.versions(of: item.entry), [1])
    XCTAssertEqual(try session.queryKeys(KeyQuery(space: "default")).count, 0)
    XCTAssertEqual(try session.queryKeys(KeyQuery(space: "work")).count, 1)
    XCTAssertEqual(try session.read(after, key: key).value, Data("FAKE-MANAGEMENT-SECRET".utf8))
  }

  func testTagsSearchAndMetadataQueriesNeedNoNewPrompt() throws {
    try put(metadata: KeyMetadata(title: "支付服务", tags: ["prod", "api"], notes: "轮换联系负责人"))
    try put("demo/dev", metadata: KeyMetadata(tags: ["dev", "api"]))
    let count = backend.prompts.count
    XCTAssertEqual(
      try session.queryKeys(KeyQuery(tags: ["API", "prod"])).map(\.ref), ["demo/token"])
    XCTAssertEqual(try session.queryKeys(KeyQuery(text: "支付")).count, 1)
    XCTAssertEqual(try session.queryKeys(KeyQuery(text: "负责人")).count, 1)
    XCTAssertEqual(try session.tags().first { $0.name == "api" }?.count, 2)
    XCTAssertEqual(backend.prompts.count, count)
  }

  func testMetadataSurvivesValueRotationAndIndexRepair() throws {
    let metadata = KeyMetadata(title: "Production", tags: ["prod"], notes: "description")
    let item = try put(metadata: metadata)
    try session.write(
      ref: Ref(item.ref), value: Data("FAKE-ROTATED".utf8), issuer: nil, usedIn: nil,
      existing: item, key: key)
    XCTAssertEqual(try session.find(Ref(item.ref))?.record.metadata, metadata)
    _ = try session.repairIndex(key: key)
    XCTAssertEqual(try session.find(Ref(item.ref))?.record.metadata, metadata)
  }

  func testArchiveRestoreAndSpaceRemovalRespectArchivedItems() throws {
    try session.createSpace(id: "work", name: "Work", key: key)
    let item = try put(metadata: KeyMetadata(space: "work", tags: ["prod"]))
    var metadata = item.record.metadata
    metadata.archived = true
    try update(item, metadata)
    XCTAssertNil(try session.find(Ref(item.ref)))
    XCTAssertThrowsError(try session.read(item, key: key), "旧列表快照不能绕过刚发生的归档")
    let archived = try XCTUnwrap(session.find(Ref(item.ref), includeArchived: true))
    XCTAssertThrowsError(try session.read(archived, key: key))
    XCTAssertThrowsError(
      try session.write(
        ref: Ref(item.ref), value: Data("FAKE".utf8), issuer: nil,
        usedIn: nil, existing: nil, key: key))
    XCTAssertEqual(try session.queryKeys(KeyQuery(scope: .archived)).count, 1)
    XCTAssertEqual(try session.tags().count, 0)
    XCTAssertEqual(try session.tags(includeArchived: true).count, 1)
    XCTAssertThrowsError(try session.removeSpace(id: "work", key: key))
    _ = try session.repairIndex(key: key)
    XCTAssertTrue(
      try XCTUnwrap(session.find(Ref(item.ref), includeArchived: true)).record.metadata.archived)
    metadata.archived = false
    try update(try XCTUnwrap(session.find(Ref(item.ref), includeArchived: true)), metadata)
    XCTAssertNotNil(try session.find(Ref(item.ref)))
  }

  func testStaleMetadataUpdateAndInvalidSpaceDoNotChangeIndex() throws {
    let item = try put()
    try update(item, KeyMetadata(title: "New title"))
    let file = session.store.indexDir.appendingPathComponent(item.entry + ".kagi")
    let before = try Data(contentsOf: file)
    XCTAssertThrowsError(try update(item, KeyMetadata(tags: ["stale"])))
    let current = try XCTUnwrap(session.find(Ref(item.ref)))
    XCTAssertThrowsError(try update(current, KeyMetadata(space: "missing")))
    XCTAssertEqual(try Data(contentsOf: file), before)
  }

  func testWrongAuthorizationCannotWriteManagementOrValues() throws {
    let item = try put()
    let wrong = Crypto.newKey()
    XCTAssertThrowsError(try session.createSpace(id: "no", name: "No", key: wrong))
    XCTAssertThrowsError(
      try session.updateKey(
        item, metadata: KeyMetadata(title: "No"), issuer: nil, usedIn: nil, key: wrong))
    XCTAssertThrowsError(
      try session.write(
        ref: Ref("demo/no"), value: Data("FAKE".utf8), issuer: nil,
        usedIn: nil, existing: nil, key: wrong))
    XCTAssertEqual(try session.spaces().count, 1)
    XCTAssertEqual(try session.listings().count, 1)
  }

  func testLegacyIndexIsReadWithoutRewritingAndUpgradesOnEdit() throws {
    let item = try put()
    let payload: [String: Any] = [
      "ref": item.ref, "created": item.record.created,
      "updated": item.record.updated, "latestVersion": 1,
    ]
    let box = try Crypto.seal(
      JSONSerialization.data(withJSONObject: payload), key: session.indexKey(),
      binding: Binding.index(vault: session.vault.vault, entry: item.entry))
    try session.store.writeIndex(
      IndexFile(format: Format.index, vault: session.vault.vault, entry: item.entry, box: box))
    let file = session.store.indexDir.appendingPathComponent(item.entry + ".kagi")
    let before = try Data(contentsOf: file)
    let legacy = try XCTUnwrap(session.find(Ref(item.ref)))
    XCTAssertEqual(legacy.record.metadata, KeyMetadata())
    XCTAssertEqual(try Data(contentsOf: file), before)
    try update(legacy, KeyMetadata(tags: ["new"]))
    XCTAssertEqual(try session.store.indexFiles().first?.format, Format.managedIndex)
  }

  func testManagementMetadataIsEncryptedAndTamperedCatalogIsRejected() throws {
    try session.createSpace(id: "work", name: "PRIVATE_SPACE_DISPLAY_NAME", key: key)
    try put(
      metadata: KeyMetadata(
        title: "PRIVATE_KEY_DISPLAY_NAME", space: "work", tags: ["private-tag-marker"]))
    let catalogURL = session.store.root.appendingPathComponent("catalog.kagi")
    let catalog = try Data(contentsOf: catalogURL)
    XCTAssertFalse(String(decoding: catalog, as: UTF8.self).contains("PRIVATE_SPACE_DISPLAY_NAME"))
    for file in try FileManager.default.contentsOfDirectory(
      at: session.store.indexDir, includingPropertiesForKeys: nil)
    {
      let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
      XCTAssertFalse(text.contains("PRIVATE_KEY_DISPLAY_NAME"))
      XCTAssertFalse(text.contains("private-tag-marker"))
    }
    var corrupted = try JSONDecoder().decode(CatalogFile.self, from: catalog)
    corrupted.box = "invalid"
    try JSONEncoder().encode(corrupted).write(to: catalogURL)
    XCTAssertThrowsError(try session.spaces())
    XCTAssertThrowsError(try session.listings())
  }

  func testInvalidTagsAndTitlesAreRejectedBeforeWriting() throws {
    let item = try put()
    for metadata in [
      KeyMetadata(tags: [""]), KeyMetadata(tags: Array(repeating: "tag", count: 33)),
      KeyMetadata(title: "bad\u{1B}title"), KeyMetadata(space: "a/b"),
    ] {
      XCTAssertThrowsError(try update(item, metadata))
    }
    XCTAssertEqual(try session.find(Ref(item.ref))?.record.metadata, KeyMetadata())
  }
}
