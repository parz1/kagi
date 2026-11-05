import CryptoKit
import Foundation

/// 新建库：先在内存里准备好一切，你确认抄下恢复密钥之后才写文件。
public struct PendingVault {
  public let store: VaultStore
  public let vault: VaultFile
  public let device: DeviceFile
  public let recovery: RecoveryFile
  public let state: DeviceState
  public let recoveryKey: RecoveryKey

  /// 写库文件和这台 Mac 的状态。
  public func commit(local: LocalStore) throws {
    try store.create(vault: vault, device: device, recovery: recovery)
    try local.save(state)
  }
}

/// 一条值的名字和元数据，加上它在库里的条目 ID。
public struct Listing: Codable, Sendable {
  public let entry: String
  public let record: IndexRecord
  /// Opaque optimistic-concurrency token; wall-clock/version equality is insufficient after sync.
  public let revision: String
  public var ref: String { record.ref }
}

/// 库层面的操作。命令行和测试都通过它来用库。
public enum Kagi {
  /// 准备新建库。会在设备密钥上试解一次（弹指纹框），确认这台 Mac 能用。
  public static func prepareInit(
    at root: URL, deviceName: String, backend: KeyBackend, reason: (String) -> String
  ) throws -> PendingVault {
    let store = VaultStore(root: root)
    guard !store.exists else {
      throw KagiError(.config, "\(root.path) 里已经有库了。", hint: "要让这台 Mac 加入它，用 kagi recover。")
    }
    let vaultID = Base32.encode(Crypto.randomBytes(16)).lowercased()
    let secretKey = Crypto.newKey()
    let indexKey = Crypto.newKey()
    let created = Timestamp.now()
    let vault = VaultFile(
      format: Format.vault, vault: vaultID, created: created,
      keyCheck: Crypto.keyCheck(secretKey, vault: vaultID, purpose: .secret),
      indexKeyCheck: Crypto.keyCheck(indexKey, vault: vaultID, purpose: .index))

    let (device, state) = try enroll(
      vault: vault, root: root, secretKey: secretKey, indexKey: indexKey, deviceName: deviceName,
      backend: backend, reason: reason(shortID(vaultID)))

    let recoveryKey = RecoveryKey.generate()
    let kek = recoveryKey.keyEncryptionKey(vault: vaultID)
    let recovery = RecoveryFile(
      format: Format.recovery, vault: vaultID,
      secretWrap: try Crypto.seal(
        Crypto.keyData(secretKey), key: kek,
        binding: Binding.recovery(vault: vaultID, purpose: .secret)),
      indexWrap: try Crypto.seal(
        Crypto.keyData(indexKey), key: kek,
        binding: Binding.recovery(vault: vaultID, purpose: .index)))

    return PendingVault(
      store: store, vault: vault, device: device, recovery: recovery, state: state,
      recoveryKey: recoveryKey)
  }

  /// 用恢复密钥让这台 Mac 加入已有的库。会弹指纹框确认新的设备密钥能用。
  public static func recover(
    at root: URL, recoveryKey: RecoveryKey, deviceName: String, backend: KeyBackend,
    local: LocalStore,
    reason: (String) -> String
  ) throws -> (vault: VaultFile, device: DeviceFile) {
    let store = VaultStore(root: root)
    let vault = try store.readVault()
    let recovery = try store.readRecovery()
    guard recovery.vault == vault.vault else {
      throw KagiError(.dataError, "keys/recovery.json 不属于这个库，可能被调换过。")
    }
    let kek = recoveryKey.keyEncryptionKey(vault: vault.vault)
    let secretKey: SymmetricKey
    let indexKey: SymmetricKey
    do {
      secretKey = SymmetricKey(
        data: try Crypto.open(
          recovery.secretWrap, key: kek,
          binding: Binding.recovery(vault: vault.vault, purpose: .secret)))
      indexKey = SymmetricKey(
        data: try Crypto.open(
          recovery.indexWrap, key: kek,
          binding: Binding.recovery(vault: vault.vault, purpose: .index)))
    } catch {
      throw KagiError(
        .dataError, "这把恢复密钥解不开这个库。", hint: "它可能属于别的库。请确认库的位置和恢复密钥是一对。")
    }
    guard Crypto.keyCheck(secretKey, vault: vault.vault, purpose: .secret) == vault.keyCheck,
      Crypto.keyCheck(indexKey, vault: vault.vault, purpose: .index) == vault.indexKeyCheck
    else {
      throw KagiError(.dataError, "vault.json 里的校验值和恢复密钥解出来的钥匙对不上，库可能被改过。")
    }
    let (device, state) = try enroll(
      vault: vault, root: root, secretKey: secretKey, indexKey: indexKey, deviceName: deviceName,
      backend: backend, reason: reason(shortID(vault.vault)))
    try store.withWriteLock {
      try store.writeDevice(device)
      try local.save(state)
    }
    return (vault, device)
  }

  /// 为这台 Mac 新建两把设备密钥，把库内密钥包给它们，再用要求指纹的那把试解一次。
  static func enroll(
    vault: VaultFile, root: URL, secretKey: SymmetricKey, indexKey: SymmetricKey,
    deviceName: String,
    backend: KeyBackend, reason: String
  ) throws -> (DeviceFile, DeviceState) {
    guard backend.isAvailable else {
      if Diagnostics.isSandboxed() == true {
        throw describe(.blocked("Secure Enclave 不可用"), action: .enroll, byAgent: false)
      }
      throw KagiError(.config, "这台 Mac 没有 Secure Enclave，kagi 用不了。")
    }
    let deviceID = "mac-" + Base32.encode(Crypto.randomBytes(5)).lowercased()
    let secretPair: DeviceKeyPair
    let indexPair: DeviceKeyPair
    do {
      secretPair = try backend.makeKey(requiresUserPresence: true)
      indexPair = try backend.makeKey(requiresUserPresence: false)
    } catch let failure as KeyFailure {
      throw describe(failure, action: .enroll, byAgent: false)
    }
    let secretBinding = Binding.device(vault: vault.vault, device: deviceID, purpose: .secret)
    let indexBinding = Binding.device(vault: vault.vault, device: deviceID, purpose: .index)
    let device = DeviceFile(
      format: Format.device, vault: vault.vault, device: deviceID, name: deviceName,
      created: Timestamp.now(),
      secretPublicKey: Crypto.publicKeyText(secretPair.publicKey),
      indexPublicKey: Crypto.publicKeyText(indexPair.publicKey),
      secretWrap: try Crypto.hpkeSeal(
        Crypto.keyData(secretKey), to: secretPair.publicKey, binding: secretBinding),
      indexWrap: try Crypto.hpkeSeal(
        Crypto.keyData(indexKey), to: indexPair.publicKey, binding: indexBinding))

    // 试解一次：确认指纹能用，也确认包装没问题。
    let check: Data
    do {
      check = try backend.openWithPresence(
        device.secretWrap, blob: secretPair.blob, binding: secretBinding, reason: reason)
      _ = try backend.openSilently(device.indexWrap, blob: indexPair.blob, binding: indexBinding)
    } catch let failure as KeyFailure {
      throw describe(failure, action: .enroll, byAgent: false)
    }
    guard check == Crypto.keyData(secretKey) else {
      throw KagiError(.software, "设备密钥试解出来的内容不对。")
    }

    let state = DeviceState(
      format: Format.local, vaultPath: root.path, vault: vault.vault, device: deviceID,
      created: device.created,
      keyCheck: vault.keyCheck, indexKeyCheck: vault.indexKeyCheck,
      secretKeyBlob: secretPair.blob.base64EncodedString(),
      indexKeyBlob: indexPair.blob.base64EncodedString())
    return (device, state)
  }

  public static func shortID(_ vaultID: String) -> String {
    "k-" + vaultID.prefix(4)
  }

  public enum Action: Sendable {
    case enroll
    case read
    case write
  }

  /// 把设备密钥的错误翻译成给人或 agent 看的话。
  /// 系统验证超时（AUTH-001）：说明可能的原因，并给出下一步。
  public static func timedOut(
    _ seconds: Int, nothing: String = "没有交出任何值，命令没有运行。", byAgent: Bool
  ) -> KagiError {
    let blockers = Diagnostics.promptBlockers()
    let cause =
      blockers.isEmpty
      ? "验证框可能没被注意到，也可能没能显示出来。"
      : blockers.joined()
    let next =
      byAgent
      ? "请停下来告诉用户，不要反复重试。可以请用户分别在自己的终端和这里运行 kagi doctor --prompt 对比。"
      : "运行 kagi doctor --prompt 检查这个环境能否弹出验证框。"
    return KagiError(
      .tempFail, "等了 \(seconds) 秒，系统验证没有完成，已取消。\(nothing)", hint: "\(cause)\n\(next)",
      audit: "timedOut")
  }

  public static func describe(_ failure: KeyFailure, action: Action, byAgent: Bool) -> KagiError {
    let nothing: String
    switch action {
    case .enroll: nothing = "这台 Mac 没有加入库。"
    case .read: nothing = "没有交出任何值，命令没有运行。"
    case .write: nothing = "什么都没存。"
    }
    switch failure {
    case .denied:
      if byAgent {
        return KagiError(.denied, "用户拒绝了这次请求，\(nothing)", hint: "请停下来问用户怎么做，不要换一种方式重试。")
      }
      return KagiError(.denied, "你取消了，\(nothing)")
    case .locked:
      return KagiError(
        .tempFail, "屏幕锁着，弹不出指纹框。\(nothing)", hint: byAgent ? "请等用户回来后再试。" : "解锁屏幕后再试。")
    case .tampered:
      return KagiError(.dataError, "解密失败：库里的文件被改过，或者不属于这台 Mac 的钥匙。\(nothing)")
    case .timedOut(let seconds):
      return Kagi.timedOut(seconds, nothing: nothing, byAgent: byAgent)
    case .blocked(let detail):
      return KagiError(
        .tempFail, "kagi 运行在沙箱里，连不上系统验证和 Secure Enclave，验证框弹不出来。\(nothing)",
        hint: "重试没有用。需要由用户决定是否在 agent 的设置里允许 kagi 在沙箱外运行，运行 kagi doctor 查看说明；不要设法绕开系统验证。\n系统返回：\(detail)",
        audit: "blocked")
    case .other(let detail):
      return KagiError(.software, "Secure Enclave 出错：\(detail)")
    }
  }
}

/// 已经加入库的这台 Mac 打开库。读名字和元数据不弹框；要值、要写入时才弹指纹框。
public final class Session {
  public let state: DeviceState
  public let store: VaultStore
  public let vault: VaultFile
  let backend: KeyBackend
  let device: DeviceFile
  var cachedIndexKey: SymmetricKey?

  public init(local: LocalStore, backend: KeyBackend) throws {
    guard let state = try local.load() else {
      throw KagiError(.config, "这台 Mac 还没有设置 kagi。", hint: "第一次用：kagi init。换了新 Mac：kagi recover。")
    }
    self.state = state
    self.backend = backend
    store = VaultStore(root: URL(fileURLWithPath: state.vaultPath, isDirectory: true))
    guard store.exists else {
      throw KagiError(
        .config, "在 \(state.vaultPath) 找不到库。", hint: "网盘可能还没同步下来，或者库被移走了。")
    }
    vault = try store.readVault()
    guard vault.vault == state.vault else {
      throw KagiError(.dataError, "\(state.vaultPath) 里的库不是这台 Mac 加入的那个（ID 不同）。")
    }
    guard vault.keyCheck == state.keyCheck, vault.indexKeyCheck == state.indexKeyCheck else {
      throw KagiError(
        .dataError, "vault.json 里的校验值和这台 Mac 记下的不一样，库文件可能被人改过。",
        hint: "先别继续用，确认网盘上的库是不是被动过。")
    }
    device = try store.readDevice(state.device)
  }

  public var shortID: String { Kagi.shortID(vault.vault) }

  // MARK: 名字和元数据（不弹框）

  func indexKey() throws -> SymmetricKey {
    if let key = cachedIndexKey { return key }
    let binding = Binding.device(vault: vault.vault, device: device.device, purpose: .index)
    guard let blob = Data(base64Encoded: state.indexKeyBlob) else {
      throw KagiError(.config, "这台 Mac 的 device.json 坏了。", hint: "用恢复密钥重新加入：kagi recover。")
    }
    let data: Data
    do {
      data = try backend.openSilently(device.indexWrap, blob: blob, binding: binding)
    } catch KeyFailure.locked {
      throw KagiError(.tempFail, "屏幕锁着，读不了库里的名字。", hint: "解锁屏幕后再试。")
    } catch let failure as KeyFailure {
      throw Kagi.describe(failure, action: .read, byAgent: false)
    }
    let key = SymmetricKey(data: data)
    guard Crypto.keyCheck(key, vault: vault.vault, purpose: .index) == state.indexKeyCheck else {
      throw KagiError(.dataError, "索引密钥和这台 Mac 记下的校验值对不上，库里的钥匙可能被调包了。")
    }
    cachedIndexKey = key
    return key
  }

  /// 所有条目的名字和元数据，按引用排序。解不开的条目抛错，不悄悄跳过。
  public func listings(includeArchived: Bool = false) throws -> [Listing] {
    try checkedListings(validateEntries: true).filter {
      includeArchived || !$0.record.metadata.archived
    }
  }

  func checkedListings(validateEntries: Bool) throws -> [Listing] {
    try store.ensureSyncReady()
    let key = try indexKey()
    let result = try store.indexFiles().map { file -> Listing in
      guard file.vault == vault.vault else {
        throw KagiError(.dataError, "index/\(file.entry).kagi 不属于这个库。")
      }
      let plain: Data
      do {
        plain = try Crypto.open(
          file.box, key: key,
          binding: Binding.index(vault: vault.vault, entry: file.entry, format: file.format))
      } catch {
        throw KagiError(.dataError, "index/\(file.entry).kagi 解不开，可能被改过。")
      }
      let record = try JSON.decode(IndexRecord.self, from: plain, file: "index/\(file.entry).kagi")
      guard (file.format == Format.typedIndex) == (record.kind != .secret) else {
        throw KagiError(.dataError, "索引格式与凭据类型不一致。")
      }
      guard (try? Ref(record.ref)) != nil, let normalized = try? record.metadata.normalized(),
        normalized == record.metadata
      else { throw KagiError(.dataError, "条目的管理字段无效。") }
      return Listing(entry: file.entry, record: record,
        revision: Data(SHA256.hash(data: Data(file.box.utf8))).base64EncodedString())
    }.sorted { $0.ref < $1.ref }
    guard Set(result.map(\.ref)).count == result.count else {
      throw KagiError(.dataError, "库里有重复引用，可能发生了多设备冲突。请先保留冲突文件并人工核对。")
    }
    let validSpaces = Set(try spaces().map(\.id))
    guard result.allSatisfy({ validSpaces.contains($0.record.metadata.space) }) else {
      throw KagiError(.dataError, "条目引用了缺失的 Space，请先确认目录同步完成。")
    }
    if validateEntries {
      guard Set(try store.entryIDs()) == Set(result.map(\.entry)) else {
        throw KagiError(.dataError, "条目与索引不完整，请先确认同步完成，再运行 kagi repair-index。")
      }
      for listing in result {
        guard try store.versions(of: listing.entry).last == listing.record.latestVersion else {
          throw KagiError(.dataError, "\(listing.ref) 的版本与索引不一致，请先确认同步完成，再运行 kagi repair-index。")
        }
      }
    }
    return result
  }

  public func find(_ ref: Ref, includeArchived: Bool = false) throws -> Listing? {
    try listings(includeArchived: includeArchived).first { $0.ref == ref.path }
  }

  // MARK: 值（弹框）

  /// 用要求指纹的设备密钥解开库密钥。reason 写在指纹框里。
  public func unlock(reason: String, action: Kagi.Action, byAgent: Bool) throws -> SymmetricKey {
    guard let blob = Data(base64Encoded: state.secretKeyBlob) else {
      throw KagiError(.config, "这台 Mac 的 device.json 坏了。", hint: "用恢复密钥重新加入：kagi recover。")
    }
    let binding = Binding.device(vault: vault.vault, device: device.device, purpose: .secret)
    let data: Data
    do {
      data = try backend.openWithPresence(
        device.secretWrap, blob: blob, binding: binding, reason: reason)
    } catch let failure as KeyFailure {
      throw Kagi.describe(failure, action: action, byAgent: byAgent)
    }
    let key = SymmetricKey(data: data)
    guard Crypto.keyCheck(key, vault: vault.vault, purpose: .secret) == state.keyCheck else {
      throw KagiError(.dataError, "库密钥和这台 Mac 记下的校验值对不上，库里的钥匙可能被调包了。")
    }
    return key
  }

  /// 读一条的最新版本。
  public func read(_ listing: Listing, key: SymmetricKey, kind: CredentialKind = .secret) throws
    -> (version: Int, value: Data)
  {
    guard listing.record.kind == kind else { throw KagiError(.usage, "凭据类型不匹配，不能作为普通 key 读取。") }
    return try store.withWriteLock {
      guard
        let current = try checkedListings(validateEntries: true).first(where: {
          $0.entry == listing.entry
        }),
        !current.record.metadata.archived
      else { throw KagiError(.notFound, "此 key 已归档或不存在，请先核对。") }
      guard current.record == listing.record, current.revision == listing.revision else {
        throw KagiError(.tempFail, "确认期间条目已变化，请重新核对后请求使用。")
      }
      guard let version = try store.versions(of: listing.entry).last else {
        throw KagiError(.dataError, "\(listing.ref) 在库里没有任何版本的文件，可能还没同步下来。")
      }
      let file = try store.readEntry(listing.entry, version: version)
      guard file.vault == vault.vault else {
        throw KagiError(.dataError, "\(listing.ref) 的文件不属于这个库。")
      }
      let binding = Binding.entry(
        vault: vault.vault, entry: listing.entry, version: version, created: file.created,
        format: file.format)
      let plainData: Data
      do {
        plainData = try Crypto.open(file.box, key: key, binding: binding)
      } catch {
        throw KagiError(.dataError, "\(listing.ref) 的第 \(version) 版解不开，可能被改过。")
      }
      let plain = try JSON.decode(
        EntryPlain.self, from: plainData, file: "\(listing.ref) 第 \(version) 版")
      guard plain.ref == listing.ref, plain.kind == kind,
        (file.format == Format.typedEntry) == (plain.kind != .secret),
        let value = Data(base64Encoded: plain.value)
      else {
        throw KagiError(.dataError, "\(listing.ref) 的第 \(version) 版里写的是别的条目，可能被调换过。")
      }
      return (version, value)
    }
  }

  /// 存一个新版本。新条目从第 1 版开始；已有的条目在最新版本上加一，旧版本不删。
  @discardableResult
  public func write(
    ref: Ref, value: Data, issuer: String?, usedIn: String?, existing: Listing?, key: SymmetricKey,
    metadata: KeyMetadata? = nil, kind: CredentialKind = .secret
  ) throws -> Int {
    try requireSecret(key)
    switch kind {
    case .secret: break
    case .totp: _ = try JSON.decode(TOTPCredential.self, from: value, file: "TOTP 凭据").code(at: 0)
    case .passkey:
      try JSON.decode(PasskeyCredential.self, from: value, file: "Passkey 凭据").validate()
    }
    let metadata = try (metadata ?? existing?.record.metadata ?? KeyMetadata()).normalized()
    return try store.withWriteLock {
      let current = try find(ref, includeArchived: true)
      guard current == nil || current?.record.kind == kind else {
        throw KagiError(.usage, "不能改变已有凭据的类型。")
      }
      guard kind != .passkey || current == nil else {
        throw KagiError(.usage, "已注册的 Passkey 不能覆盖，请使用新的引用注册。")
      }
      guard current?.record.metadata.archived != true, !metadata.archived else {
        throw KagiError(.usage, "此 key 已归档，请先恢复后再更新值。")
      }
      guard try spaces().contains(where: { $0.id == metadata.space }) else {
        throw KagiError(.notFound, "没有 Space \(metadata.space)。")
      }
      guard current?.entry == existing?.entry, current?.record == existing?.record,
        current?.revision == existing?.revision else {
        throw KagiError(.tempFail, "确认期间条目已被另一个写入修改，什么都没存。请核对后重新运行。")
      }
      let entry = existing?.entry ?? Base32.encode(Crypto.randomBytes(10)).lowercased()
      let latest = try store.versions(of: entry).last ?? 0
      let version = latest + 1
      let created = Timestamp.now()
      let format = kind == .secret ? Format.entry : Format.typedEntry
      let plain = try JSON.encode(
        EntryPlain(ref: ref.path, value: value.base64EncodedString(), kind: kind))
      let file = EntryFile(
        format: format, vault: vault.vault, entry: entry, version: version, created: created,
        box: try Crypto.seal(
          plain, key: key,
          binding: Binding.entry(
            vault: vault.vault, entry: entry, version: version, created: created, format: format)))
      try store.writeEntry(file)

      let record = IndexRecord(
        ref: ref.path, issuer: issuer ?? existing?.record.issuer,
        usedIn: usedIn ?? existing?.record.usedIn,
        created: existing?.record.created ?? created, updated: created, latestVersion: version,
        metadata: metadata, kind: kind)
      try saveIndex(entry: entry, record: record)
      return version
    }
  }

  /// 从通过认证的条目重建缺失或过期索引；先验证全库，再开始写入。
  public func repairIndex(key: SymmetricKey) throws -> Int {
    try store.withWriteLock {
      let old = try checkedListings(validateEntries: false)
      let oldByEntry = Dictionary(uniqueKeysWithValues: old.map { ($0.entry, $0.record) })
      let ids = try store.entryIDs()
      guard Set(oldByEntry.keys).isSubset(of: Set(ids)) else {
        throw KagiError(.dataError, "索引对应的条目文件缺失。请恢复文件或等待同步，不能重建索引。")
      }
      var records: [(String, IndexRecord)] = []
      var refs = Set<String>()
      for id in ids {
        guard let version = try store.versions(of: id).last else {
          throw KagiError(.dataError, "条目 \(id) 没有版本文件。")
        }
        let file = try store.readEntry(id, version: version)
        guard file.vault == vault.vault else { throw KeyFailure.tampered }
        let plain = try Crypto.open(
          file.box, key: key,
          binding: Binding.entry(
            vault: vault.vault, entry: id, version: version, created: file.created,
            format: file.format))
        let value = try JSON.decode(EntryPlain.self, from: plain, file: id)
        _ = try Ref(value.ref)
        guard Data(base64Encoded: value.value) != nil, refs.insert(value.ref).inserted,
          (file.format == Format.typedEntry) == (value.kind != .secret)
        else {
          throw KagiError(.dataError, "条目损坏或引用重复，索引没有修改。")
        }
        let prior = oldByEntry[id]
        guard
          prior == nil
            || (prior!.ref == value.ref && prior!.latestVersion <= version
              && prior!.kind == value.kind)
        else {
          throw KagiError(.dataError, "条目与旧索引不一致，可能缺少新版本。索引没有修改。")
        }
        records.append(
          (
            id,
            IndexRecord(
              ref: value.ref, issuer: prior?.issuer, usedIn: prior?.usedIn,
              created: prior?.created ?? file.created,
              updated: (prior?.latestVersion == version ? prior?.updated : nil) ?? file.created,
              latestVersion: version,
              metadata: prior?.metadata ?? KeyMetadata(archived: true), kind: value.kind
            )
          ))
      }
      for (id, record) in records {
        try saveIndex(entry: id, record: record)
      }
      return records.count
    }
  }

  public func devices() throws -> [DeviceFile] {
    try store.devices()
  }
}
