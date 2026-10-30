import CryptoKit
import Foundation

extension Session {
  func requireSecret(_ key: SymmetricKey) throws {
    guard Crypto.keyCheck(key, vault: vault.vault, purpose: .secret) == state.keyCheck else {
      throw KagiError(.denied, "管理写入需要本次验证得到的库密钥。")
    }
  }

  public func spaces() throws -> [SpaceRecord] {
    try store.ensureSyncReady()
    guard let file = try store.readCatalog() else {
      return [
        SpaceRecord(id: "default", name: "默认", created: vault.created, updated: vault.created)
      ]
    }
    guard file.format == Format.catalog, file.vault == vault.vault else {
      throw KeyFailure.tampered
    }
    let plain = try Crypto.open(
      file.box, key: indexKey(), binding: Binding.catalog(vault: vault.vault))
    let record = try JSON.decode(CatalogRecord.self, from: plain, file: "catalog.kagi")
    guard record.spaces.contains(where: { $0.id == "default" }),
      Set(record.spaces.map(\.id)).count == record.spaces.count
    else {
      throw KagiError(.dataError, "Space 目录不完整或存在重复 ID。")
    }
    for space in record.spaces {
      do {
        try ManagementText.spaceID(space.id)
        guard let name = try ManagementText.optional(space.name, limit: 120), name == space.name
        else {
          throw KagiError(.dataError, "Space 名称无效。")
        }
      } catch { throw KagiError(.dataError, "Space 目录包含无效字段。") }
    }
    return record.spaces.sorted { $0.id < $1.id }
  }

  private func saveSpaces(_ spaces: [SpaceRecord]) throws {
    let box = try Crypto.seal(
      try JSON.encode(CatalogRecord(spaces: spaces)), key: indexKey(),
      binding: Binding.catalog(vault: vault.vault))
    try store.writeCatalog(CatalogFile(format: Format.catalog, vault: vault.vault, box: box))
  }

  public func createSpace(id: String, name: String, key: SymmetricKey) throws {
    try requireSecret(key)
    try ManagementText.spaceID(id)
    guard let name = try ManagementText.optional(name, limit: 120) else {
      throw KagiError(.usage, "Space 名称不能为空。")
    }
    try store.withWriteLock {
      var records = try spaces()
      guard !records.contains(where: { $0.id == id }) else {
        throw KagiError(.usage, "Space \(id) 已存在。")
      }
      let now = Timestamp.now()
      records.append(SpaceRecord(id: id, name: name, created: now, updated: now))
      try saveSpaces(records)
    }
  }

  public func renameSpace(id: String, name: String, key: SymmetricKey) throws {
    try requireSecret(key)
    guard let name = try ManagementText.optional(name, limit: 120) else {
      throw KagiError(.usage, "Space 名称不能为空。")
    }
    try store.withWriteLock {
      var records = try spaces()
      guard let index = records.firstIndex(where: { $0.id == id }) else {
        throw KagiError(.notFound, "没有 Space \(id)。")
      }
      records[index].name = name
      records[index].updated = Timestamp.now()
      try saveSpaces(records)
    }
  }

  public func removeSpace(id: String, key: SymmetricKey) throws {
    try requireSecret(key)
    try store.withWriteLock {
      guard id != "default" else { throw KagiError(.usage, "默认 Space 不能删除。") }
      var records = try spaces()
      guard records.contains(where: { $0.id == id }) else {
        throw KagiError(.notFound, "没有 Space \(id)。")
      }
      guard
        try checkedListings(validateEntries: true).allSatisfy({ $0.record.metadata.space != id })
      else {
        throw KagiError(.usage, "Space 中仍有 key（包括已归档项），请先移动它们。")
      }
      records.removeAll { $0.id == id }
      try saveSpaces(records)
    }
  }

  /// 全部字段以调用者读到的快照为基础更新，避免 GUI/CLI 并发时丢失修改。
  public func updateKey(
    _ expected: Listing, metadata: KeyMetadata, issuer: String?, usedIn: String?,
    key: SymmetricKey
  ) throws {
    try requireSecret(key)
    let metadata = try metadata.normalized()
    let issuer = try ManagementText.optional(issuer, limit: 200)
    let usedIn = try ManagementText.optional(usedIn, limit: 1000)
    try store.withWriteLock {
      let current = try checkedListings(validateEntries: true).first { $0.entry == expected.entry }
      guard let current, current.record == expected.record, current.revision == expected.revision else {
        throw KagiError(.tempFail, "条目已变化，请重新读取后再修改。")
      }
      guard try spaces().contains(where: { $0.id == metadata.space }) else {
        throw KagiError(.notFound, "没有 Space \(metadata.space)。")
      }
      var record = current.record
      record.metadata = metadata
      record.issuer = issuer
      record.usedIn = usedIn
      record.updated = Timestamp.now()
      try saveIndex(entry: current.entry, record: record)
    }
  }

  func saveIndex(entry: String, record: IndexRecord) throws {
    let format = record.kind == .secret ? Format.managedIndex : Format.typedIndex
    try store.writeIndex(
      IndexFile(
        format: format, vault: vault.vault, entry: entry,
        box: Crypto.seal(
          try JSON.encode(record), key: indexKey(),
          binding: Binding.index(vault: vault.vault, entry: entry, format: format))))
  }

  public func queryKeys(_ query: KeyQuery) throws -> [Listing] {
    let tags = Set(try ManagementText.tags(query.tags))
    let spaces = try spaces()
    if let id = query.space, !spaces.contains(where: { $0.id == id }) {
      throw KagiError(.notFound, "没有 Space \(id)。")
    }
    let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return try checkedListings(validateEntries: true).filter { item in
      let metadata = item.record.metadata
      if query.scope == .active && metadata.archived { return false }
      if query.scope == .archived && !metadata.archived { return false }
      if let space = query.space, metadata.space != space { return false }
      if !tags.isSubset(of: Set(metadata.tags)) { return false }
      let fields =
        [
          item.ref, metadata.title, metadata.notes, item.record.issuer, item.record.usedIn,
          metadata.space, spaces.first(where: { $0.id == metadata.space })?.name,
        ].compactMap { $0 } + metadata.tags
      return text.isEmpty || fields.contains { $0.localizedStandardContains(text) }
    }
  }

  public func tags(includeArchived: Bool = false) throws -> [TagSummary] {
    var counts: [String: Int] = [:]
    for item in try listings(includeArchived: includeArchived) {
      for tag in item.record.metadata.tags { counts[tag, default: 0] += 1 }
    }
    return counts.map { TagSummary(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
  }
}
