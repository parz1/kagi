import CryptoKit
import Foundation

public enum SyncChoice: String, Codable, Sendable { case local, remote }
public struct SyncConflictSide: Codable, Equatable, Sendable {
  public let keys: [IndexRecord]
  public let spaces: [SpaceRecord]
  public let present: Bool
}
public struct SyncConflict: Codable, Equatable, Sendable {
  public let id: String
  public let item: String
  public let base: SyncConflictSide
  public let local: SyncConflictSide
  public let remote: SyncConflictSide
}
public struct SyncResult: Codable, Sendable {
  public let revision: String?
  public let conflicts: [SyncConflict]
  public let recovered: Bool
}

struct SyncSnapshot: Codable, Equatable {
  var format = "kagi-sync/1"
  var vault: String
  var parents: [String]
  var files: [String: Data]
}
private struct SyncState: Codable {
  var transport: String
  var revision: String
}
private struct SyncPending: Codable {
  var transport: String
  var revision: String
  var snapshot: SyncSnapshot
}
private struct SyncConflictRecord: Codable {
  var localRevision: String
  var remoteRevision: String
  var conflicts: [SyncConflict]
}

extension Session {
  /// One transport per local replica. No account, provider API, wall-clock ordering or silent winner.
  /// Decisions are bound to hashes of the base and both branches, so stale decisions cannot apply.
  public func synchronize(
    with transport: SyncTransport, key: SymmetricKey,
    resolutions: [String: SyncChoice] = [:]
  ) throws -> SyncResult {
    try requireSecret(key)
    return try store.withWriteLock(allowPendingSync: true) {
      let stateURL = store.root.appendingPathComponent(".sync-state")
      let pendingURL = store.root.appendingPathComponent(".sync-pending")
      if FileManager.default.fileExists(atPath: pendingURL.path) {
        guard resolutions.isEmpty else { throw KagiError(.usage, "恢复中断同步时不能同时提交冲突选择。") }
        let pending: SyncPending = try syncRead(pendingURL, label: "pending", key: key)
        guard pending.transport == transport.identity else {
          throw KagiError(.config, "请使用上次的同步目标完成中断恢复。")
        }
        try validateSyncSnapshot(pending.snapshot, key: key)
        try applySyncSnapshot(pending.snapshot)
        try syncWrite(SyncState(transport: transport.identity, revision: pending.revision),
          to: stateURL, label: "state", key: key)
        try SyncIO.remove(pendingURL)
        return SyncResult(revision: pending.revision, conflicts: [], recovered: true)
      }
      let state: SyncState? = FileManager.default.fileExists(atPath: stateURL.path)
        ? try syncRead(stateURL, label: "state", key: key) : nil
      guard state == nil || state?.transport == transport.identity else {
        throw KagiError(.config, "这份本地库已绑定其他同步目标，请为其他目标使用独立副本。")
      }
      let head = try transport.head()
      var cache: [String: SyncSnapshot] = [:]
      var loadedBytes = 0
      func load(_ id: String) throws -> SyncSnapshot {
        if let value = cache[id] { return value }
        let bytes = try transport.object(id)
        loadedBytes += bytes.count
        guard loadedBytes <= 256 * 1024 * 1024 else {
          throw KagiError(.dataError, "本次同步历史超过 256 MiB 读取限制。")
        }
        guard SyncIO.hash(bytes) == id else { throw KeyFailure.tampered }
        let archive = try JSON.decode(SyncArchive.self, from: bytes, file: "sync archive")
        guard archive.vault == vault else { throw KeyFailure.tampered }
        let value = try archive.open(key: key)
        guard value.format == "kagi-sync/1", value.vault == vault.vault,
          value.parents.count <= 2, Set(value.parents).count == value.parents.count,
          value.parents.allSatisfy(SyncIO.validID) else { throw KeyFailure.tampered }
        try Self.checkSyncPaths(value.files)
        cache[id] = value
        return value
      }
      if let base = state?.revision {
        guard let head else { throw KagiError(.dataError, "远端历史消失，拒绝重新初始化以免丢失修改。") }
        var queue = [head], seen = Set<String>()
        while !queue.isEmpty, !seen.contains(base) {
          let id = queue.removeLast()
          if seen.insert(id).inserted {
            guard seen.count <= 4096 else { throw KagiError(.dataError, "同步历史过长，无法确认祖先。") }
            queue += try load(id).parents
          }
        }
        guard seen.contains(base) else {
          throw KagiError(.dataError, "远端历史回退或分叉，拒绝覆盖本机已确认的同步历史。")
        }
      }
      let local = SyncSnapshot(vault: vault.vault, parents: state.map { [$0.revision] } ?? [],
        files: try captureSyncFiles())
      try validateSyncSnapshot(local, key: key)
      let remote = try head.map(load)
      if let remote { try validateSyncSnapshot(remote, key: key) }
      let base = try state.map { try load($0.revision) }
      let merged = try mergeSync(base: base, local: local, remote: remote,
        resolutions: resolutions)
      func publish(_ snapshot: SyncSnapshot) throws -> String {
        let bytes = try SyncArchive.seal(snapshot, key: key)
        let id = try transport.put(bytes)
        guard id == SyncIO.hash(bytes) else { throw KeyFailure.tampered }
        return id
      }
      if !merged.conflicts.isEmpty {
        let localID = try publish(local)
        try syncWrite(SyncConflictRecord(localRevision: localID, remoteRevision: head!,
          conflicts: merged.conflicts), to: store.root.appendingPathComponent(".sync-conflicts"),
          label: "conflicts", key: key)
        return SyncResult(revision: head, conflicts: merged.conflicts, recovered: false)
      }
      var target = merged.snapshot
      try validateSyncSnapshot(target, key: key)
      guard target.files["keys/" + self.state.device + ".json"] != nil else {
        throw KagiError(.dataError, "合并结果移除了当前设备，拒绝应用。")
      }
      let revision: String
      if let remote, remote.files == target.files, let head, resolutions.isEmpty { revision = head }
      else {
        // Preserve the local branch too, including overwritten versions selected against later.
        let localID = try publish(local)
        target.parents = Array(Set([localID] + (head.map { [$0] } ?? []))).sorted()
        revision = try publish(target)
      }
      // Always CAS, even a download/no-op: a stale head must not advance the baseline.
      guard try transport.compareAndSwap(expected: head, replacement: revision) else {
        throw KagiError(.tempFail, "远端在同步期间变化；本机未修改，请重新同步。")
      }
      // Write-ahead recovery blocks ordinary operations until the complete target is installed.
      try syncWrite(SyncPending(transport: transport.identity, revision: revision, snapshot: target),
        to: pendingURL, label: "pending", key: key)
      try applySyncSnapshot(target)
      try syncWrite(SyncState(transport: transport.identity, revision: revision),
        to: stateURL, label: "state", key: key)
      try SyncIO.remove(pendingURL)
      try? FileManager.default.removeItem(at: store.root.appendingPathComponent(".sync-conflicts"))
      return SyncResult(revision: revision, conflicts: [], recovered: false)
    }
  }

  func saveSyncBaseline(transport: String, revision: String, key: SymmetricKey) throws {
    try syncWrite(SyncState(transport: transport, revision: revision),
      to: store.root.appendingPathComponent(".sync-state"), label: "state", key: key)
  }

  private func syncRead<T: Decodable>(_ url: URL, label: String, key: SymmetricKey) throws -> T {
    let text = String(decoding: try SyncIO.read(url), as: UTF8.self)
    let plain = try Crypto.open(text, key: key,
      binding: Data("kagi-sync-local/1|\(vault.vault)|\(label)".utf8))
    return try JSON.decode(T.self, from: plain, file: "local sync " + label)
  }
  private func syncWrite<T: Encodable>(_ value: T, to url: URL, label: String,
    key: SymmetricKey) throws {
    let text = try Crypto.seal(try JSON.encode(value), key: key,
      binding: Data("kagi-sync-local/1|\(vault.vault)|\(label)".utf8))
    try SyncIO.write(Data(text.utf8), to: url)
  }

  static func checkSyncPaths(_ files: [String: Data]) throws {
    guard files.count <= 10000, files.values.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024,
      files["vault.json"] != nil, files["keys/recovery.json"] != nil else {
      throw KagiError(.dataError, "同步快照不完整或超过限制（10000 文件 / 32 MiB）。")
    }
    try checkSyncPayloadPaths(Array(files.keys))
  }

  private static func checkSyncPayloadPaths(_ paths: [String]) throws {
    guard paths.contains("vault.json"), paths.contains("keys/recovery.json") else {
      throw KagiError(.dataError, "同步库缺少库头或恢复封装。")
    }
    func identifier(_ text: Substring) -> Bool {
      !text.isEmpty && text.count <= 64 && text.utf8.allSatisfy {
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
      }
    }
    for path in paths {
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      var valid = path == "vault.json" || path == "catalog.kagi" || path == "keys/recovery.json"
      if parts.count == 2, parts[0] == "keys", parts[1].hasSuffix(".json") {
        valid = identifier(parts[1].dropLast(5))
      }
      if parts.count == 2, parts[0] == "index", parts[1].hasSuffix(".kagi") {
        valid = identifier(parts[1].dropLast(5))
      }
      if parts.count == 3, parts[0] == "entries", identifier(parts[1]),
        parts[2].hasSuffix(".kagi"), let number = Int(parts[2].dropLast(5)),
        number > 0, number < Int.max {
        valid = parts[2] == Substring(VaultStore.versionName(number))
      }
      guard valid else { throw KagiError(.dataError, "同步快照包含不允许的文件路径。") }
    }
  }

  private func captureSyncFiles() throws -> [String: Data] {
    let paths = try syncPayloadPaths()
    guard paths.count <= 10000 else { throw KagiError(.dataError, "同步快照超过 10000 文件限制。") }
    var result: [String: Data] = [:]
    var remaining = 32 * 1024 * 1024
    for path in paths {
      let data = try SyncIO.read(store.root.appendingPathComponent(path), limit: remaining)
      remaining -= data.count
      result[path] = data
    }
    try Self.checkSyncPaths(result)
    return result
  }

  /// Inventory paths without decoding/reading the old + new transient union during install.
  private func syncPayloadPaths() throws -> [String] {
    var result: [String] = []
    // Only vault payloads travel; device blobs, logs and sync journals never do.
    func walk(_ dir: URL, prefix: String) throws {
      for url in try FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { continue }
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard info.isSymbolicLink != true else { throw KagiError(.dataError, "库中存在符号链接，拒绝同步。") }
        let path = prefix + name
        if info.isDirectory == true { try walk(url, prefix: path + "/") }
        else if info.isRegularFile == true { result.append(path) }
        else { throw KagiError(.dataError, "库中存在特殊文件，拒绝同步。") }
      }
    }
    for name in ["vault.json", "catalog.kagi"] {
      let url = store.root.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { result.append(name) }
    }
    for name in ["keys", "index", "entries"] {
      let dir = store.root.appendingPathComponent(name)
      let info = try dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      guard info.isDirectory == true, info.isSymbolicLink != true else { throw KeyFailure.tampered }
      try walk(dir, prefix: name + "/")
    }
    try Self.checkSyncPayloadPaths(result)
    return result
  }

  private func stageSync(_ snapshot: SyncSnapshot) throws -> URL {
    try Self.checkSyncPaths(snapshot.files)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kagi-sync-" + UUID().uuidString)
    try SyncIO.directory(root)
    do {
      for (path, data) in snapshot.files {
        let url = root.appendingPathComponent(path)
        try SyncIO.directory(url.deletingLastPathComponent())
        try SyncIO.write(data, to: url)
      }
      for name in ["entries", "index", "keys"] { try SyncIO.directory(root.appendingPathComponent(name)) }
      return root
    } catch { try? FileManager.default.removeItem(at: root); throw error }
  }

  func validateSyncSnapshot(_ snapshot: SyncSnapshot, key: SymmetricKey) throws {
    guard snapshot.vault == vault.vault else { throw KeyFailure.tampered }
    let root = try stageSync(snapshot)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = LocalStore(dir: root.appendingPathComponent(".local"))
    var state = self.state
    state.vaultPath = root.path
    try local.save(state)
    // A newly enrolled device may not yet appear in the older remote snapshot.
    if !FileManager.default.fileExists(atPath: root.appendingPathComponent("keys/" + state.device + ".json").path) {
      try VaultStore(root: root).writeDevice(device)
    }
    let session = try Session(local: local, backend: backend)
    guard session.vault == vault else { throw KeyFailure.tampered }
    session.cachedIndexKey = try indexKey()
    let listings = try session.checkedListings(validateEntries: true)
    for item in listings {
      for version in try session.store.versions(of: item.entry) {
        let file = try session.store.readEntry(item.entry, version: version)
        guard file.vault == vault.vault else { throw KeyFailure.tampered }
        let bytes = try Crypto.open(file.box, key: key, binding: Binding.entry(
          vault: vault.vault, entry: item.entry, version: version, created: file.created, format: file.format))
        let value = try JSON.decode(EntryPlain.self, from: bytes, file: "sync entry")
        guard value.ref == item.ref, value.kind == item.record.kind,
          (file.format == Format.typedEntry) == (value.kind != .secret),
          let data = Data(base64Encoded: value.value) else { throw KeyFailure.tampered }
        switch value.kind {
        case .secret: break
        case .totp: _ = try JSON.decode(TOTPCredential.self, from: data, file: "TOTP").code(at: 0)
        case .passkey: try JSON.decode(PasskeyCredential.self, from: data, file: "Passkey").validate()
        }
      }
    }
  }

  private func applySyncSnapshot(_ snapshot: SyncSnapshot) throws {
    try Self.checkSyncPaths(snapshot.files)
    // Existing regular files may be replaced; traversal through symlinks is forbidden.
    for (path, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
      let parts = path.split(separator: "/")
      var parent = store.root
      for part in parts.dropLast() {
        parent.appendPathComponent(String(part))
        try SyncIO.directory(parent)
      }
      try SyncIO.write(data, to: store.root.appendingPathComponent(path))
    }
    // Inventory after writes also makes replay safe after an interrupted partial install.
    let existing = try syncPayloadPaths()
    for path in existing where snapshot.files[path] == nil {
      try SyncIO.remove(store.root.appendingPathComponent(path))
    }
    let activeEntries = Set(snapshot.files.keys.compactMap { path -> String? in
      let parts = path.split(separator: "/")
      return parts.count == 3 && parts[0] == "entries" ? String(parts[1]) : nil
    })
    for entry in try store.entryIDs() where !activeEntries.contains(entry) {
      let dir = store.entriesDir.appendingPathComponent(entry)
      if try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty {
        try SyncIO.remove(dir)
      } else {
        // An interrupted local write can leave hidden ciphertext here. Preserve it outside
        // active entries instead of reporting success with an orphaned entry directory.
        let retired = store.root.appendingPathComponent(".sync-retired")
        try SyncIO.directory(retired)
        try SyncIO.move(dir, to: retired.appendingPathComponent(entry + "-" + UUID().uuidString))
      }
    }
  }

  private func mergeSync(base: SyncSnapshot?, local: SyncSnapshot, remote: SyncSnapshot?,
    resolutions: [String: SyncChoice]) throws -> (snapshot: SyncSnapshot, conflicts: [SyncConflict]) {
    typealias Unit = [String: Data]
    func units(_ snapshot: SyncSnapshot?) throws -> [String: Unit] {
      guard let snapshot else { return [:] }
      var result: [String: Unit] = [:]
      let indexKey = try self.indexKey()
      for (path, bytes) in snapshot.files {
        if path.hasPrefix("index/") {
          let file = try JSON.decode(IndexFile.self, from: bytes, file: "sync index")
          let plain = try Crypto.open(file.box, key: indexKey, binding: Binding.index(
            vault: vault.vault, entry: file.entry, format: file.format))
          let record = try JSON.decode(IndexRecord.self, from: plain, file: "sync index")
          var bundle: Unit = [path: bytes]
          for (name, data) in snapshot.files where name.hasPrefix("entries/\(file.entry)/") { bundle[name] = data }
          result["key:" + record.ref] = bundle
        } else if path == "catalog.kagi" {
          let file = try JSON.decode(CatalogFile.self, from: bytes, file: "sync catalog")
          let plain = try Crypto.open(file.box, key: indexKey, binding: Binding.catalog(vault: vault.vault))
          for space in try JSON.decode(CatalogRecord.self, from: plain, file: "sync catalog").spaces {
            result["space:" + space.id] = ["space": try JSON.encode(space)]
          }
        } else if !path.hasPrefix("entries/") { result["file:" + path] = [path: bytes] }
      }
      if snapshot.files["catalog.kagi"] == nil {
        let space = SpaceRecord(id: "default", name: "默认", created: vault.created, updated: vault.created)
        result["space:default"] = ["space": try JSON.encode(space)]
      }
      return result
    }
    func summary(_ groups: [String: Unit]) throws -> SyncConflictSide {
      var keys: [IndexRecord] = [], spaces: [SpaceRecord] = []
      for (name, unit) in groups {
        if name.hasPrefix("space:"), let bytes = unit["space"] {
          spaces.append(try JSON.decode(SpaceRecord.self, from: bytes, file: "sync space"))
        } else if let bytes = unit.first(where: { $0.key.hasPrefix("index/") })?.value {
          let file = try JSON.decode(IndexFile.self, from: bytes, file: "sync index")
          let plain = try Crypto.open(file.box, key: indexKey(), binding: Binding.index(
            vault: vault.vault, entry: file.entry, format: file.format))
          keys.append(try JSON.decode(IndexRecord.self, from: plain, file: "sync index"))
        }
      }
      return SyncConflictSide(keys: keys.sorted { $0.ref < $1.ref },
        spaces: spaces.sorted { $0.id < $1.id }, present: !groups.isEmpty)
    }
    let b = try units(base), l = try units(local), r = try units(remote)
    var merged: [String: Unit] = [:], conflicts: [SyncConflict] = []
    var used = Set<String>()
    var chosenUnits: [String: SyncChoice] = [:]
    for name in Set(b.keys).union(l.keys).union(r.keys).sorted() {
      let old = b[name], ours = l[name], theirs = r[name]
      if remote == nil || ours == theirs { merged[name] = ours }
      else if ours == old { merged[name] = theirs }
      else if theirs == old { merged[name] = ours }
      else {
        struct Token: Encodable { let name: String; let base: Unit?; let local: Unit?; let remote: Unit? }
        let id = SyncIO.hash(try JSON.encode(Token(name: name, base: old, local: ours, remote: theirs)))
        if let choice = resolutions[id] {
          used.insert(id)
          chosenUnits[name] = choice
          merged[name] = choice == .local ? ours : theirs
        } else {
          conflicts.append(try SyncConflict(id: id, item: name,
            base: summary(old.map { [name: $0] } ?? [:]),
            local: summary(ours.map { [name: $0] } ?? [:]),
            remote: summary(theirs.map { [name: $0] } ?? [:])))
        }
      }
    }
    // Deleting an empty Space while another device adds/moves a key into it is
    // a dependency conflict, even though the two individual records did not both change.
    func spaceUsed(by unit: Unit) throws -> String? {
      guard let bytes = unit.first(where: { $0.key.hasPrefix("index/") })?.value else { return nil }
      let file = try JSON.decode(IndexFile.self, from: bytes, file: "sync index")
      let bytesPlain = try Crypto.open(file.box, key: indexKey(), binding: Binding.index(
        vault: vault.vault, entry: file.entry, format: file.format))
      return try JSON.decode(IndexRecord.self, from: bytesPlain, file: "sync index").metadata.space
    }
    if conflicts.isEmpty {
      var missing = Set<String>()
      for (name, unit) in merged where name.hasPrefix("key:") {
        if let id = try spaceUsed(by: unit), merged["space:" + id] == nil { missing.insert(id) }
      }
      for space in missing.sorted() {
        var names = Set(["space:" + space])
        for side in [b, l, r] {
          for (name, unit) in side where name.hasPrefix("key:") {
            if try spaceUsed(by: unit) == space { names.insert(name) }
          }
        }
        func group(_ side: [String: Unit]) throws -> Unit {
          var unit: Unit = [:]
          for name in names { if let value = side[name] { unit[name] = try JSON.encode(value) } }
          return unit
        }
        struct Dependency: Encodable { let item: String; let base: Unit; let local: Unit; let remote: Unit }
        let item = "space-use:" + space
        let id = SyncIO.hash(try JSON.encode(Dependency(item: item, base: group(b), local: group(l), remote: group(r))))
        if let choice = resolutions[id] {
          used.insert(id)
          let side = choice == .local ? l : r
          for name in names {
            guard chosenUnits[name] == nil || chosenUnits[name] == choice else {
              throw KagiError(.usage, "key 与 Space 依赖的冲突选择互相矛盾，请为相关条目选择同一侧。")
            }
            chosenUnits[name] = choice
            merged[name] = side[name]
          }
        } else {
          conflicts.append(try SyncConflict(id: id, item: item,
            base: summary(b.filter { names.contains($0.key) }),
            local: summary(l.filter { names.contains($0.key) }),
            remote: summary(r.filter { names.contains($0.key) })))
        }
      }
    }
    guard Set(resolutions.keys) == used else {
      throw KagiError(.usage, "冲突选择已过期或 ID 不存在，请重新同步查看当前冲突。")
    }
    guard conflicts.isEmpty else { return (local, conflicts) }
    var files: [String: Data] = [:], spaces: [SpaceRecord] = []
    for (name, unit) in merged {
      if name.hasPrefix("space:") {
        spaces.append(try JSON.decode(SpaceRecord.self, from: unit["space"]!, file: "sync space"))
      } else {
        for (path, data) in unit {
          guard files[path] == nil else { throw KagiError(.dataError, "合并产生重复条目 ID。") }
          files[path] = data
        }
      }
    }
    // Reuse ciphertext when possible, avoiding changes on repeated no-op synchronization.
    let selectedSpaces = merged.filter { $0.key.hasPrefix("space:") }
    if selectedSpaces == l.filter({ $0.key.hasPrefix("space:") }) {
      files["catalog.kagi"] = local.files["catalog.kagi"]
    } else if let remote, selectedSpaces == r.filter({ $0.key.hasPrefix("space:") }) {
      files["catalog.kagi"] = remote.files["catalog.kagi"]
    } else {
      let box = try Crypto.seal(try JSON.encode(CatalogRecord(spaces: spaces.sorted { $0.id < $1.id })),
        key: indexKey(), binding: Binding.catalog(vault: vault.vault))
      files["catalog.kagi"] = try JSON.encode(CatalogFile(format: Format.catalog, vault: vault.vault, box: box))
    }
    return (SyncSnapshot(vault: vault.vault, parents: [], files: files), [])
  }
}
