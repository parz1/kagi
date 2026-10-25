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
public struct Listing: Sendable {
  public let entry: String
  public let record: IndexRecord
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
        Crypto.keyData(secretKey), key: kek, binding: Binding.recovery(vault: vaultID, purpose: .secret)),
      indexWrap: try Crypto.seal(
        Crypto.keyData(indexKey), key: kek, binding: Binding.recovery(vault: vaultID, purpose: .index)))

    return PendingVault(
      store: store, vault: vault, device: device, recovery: recovery, state: state, recoveryKey: recoveryKey)
  }

  /// 用恢复密钥让这台 Mac 加入已有的库。会弹指纹框确认新的设备密钥能用。
  public static func recover(
    at root: URL, recoveryKey: RecoveryKey, deviceName: String, backend: KeyBackend, local: LocalStore,
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
          recovery.secretWrap, key: kek, binding: Binding.recovery(vault: vault.vault, purpose: .secret)))
      indexKey = SymmetricKey(
        data: try Crypto.open(
          recovery.indexWrap, key: kek, binding: Binding.recovery(vault: vault.vault, purpose: .index)))
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
    try store.writeDevice(device)
    try local.save(state)
    return (vault, device)
  }

  /// 为这台 Mac 新建两把设备密钥，把库内密钥包给它们，再用要求指纹的那把试解一次。
  static func enroll(
    vault: VaultFile, root: URL, secretKey: SymmetricKey, indexKey: SymmetricKey, deviceName: String,
    backend: KeyBackend, reason: String
  ) throws -> (DeviceFile, DeviceState) {
    guard backend.isAvailable else {
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
      format: Format.device, vault: vault.vault, device: deviceID, name: deviceName, created: Timestamp.now(),
      secretPublicKey: Crypto.publicKeyText(secretPair.publicKey),
      indexPublicKey: Crypto.publicKeyText(indexPair.publicKey),
      secretWrap: try Crypto.hpkeSeal(Crypto.keyData(secretKey), to: secretPair.publicKey, binding: secretBinding),
      indexWrap: try Crypto.hpkeSeal(Crypto.keyData(indexKey), to: indexPair.publicKey, binding: indexBinding))

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
      format: Format.local, vaultPath: root.path, vault: vault.vault, device: deviceID, created: device.created,
      keyCheck: vault.keyCheck, indexKeyCheck: vault.indexKeyCheck,
      secretKeyBlob: secretPair.blob.base64EncodedString(), indexKeyBlob: indexPair.blob.base64EncodedString())
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
  public func listings() throws -> [Listing] {
    let key = try indexKey()
    return try store.indexFiles().map { file -> Listing in
      guard file.vault == vault.vault else {
        throw KagiError(.dataError, "index/\(file.entry).kagi 不属于这个库。")
      }
      let plain: Data
      do {
        plain = try Crypto.open(file.box, key: key, binding: Binding.index(vault: vault.vault, entry: file.entry))
      } catch {
        throw KagiError(.dataError, "index/\(file.entry).kagi 解不开，可能被改过。")
      }
      let record = try JSON.decode(IndexRecord.self, from: plain, file: "index/\(file.entry).kagi")
      return Listing(entry: file.entry, record: record)
    }.sorted { $0.ref < $1.ref }
  }

  public func find(_ ref: Ref) throws -> Listing? {
    try listings().first { $0.ref == ref.path }
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
      data = try backend.openWithPresence(device.secretWrap, blob: blob, binding: binding, reason: reason)
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
  public func read(_ listing: Listing, key: SymmetricKey) throws -> (version: Int, value: Data) {
    guard let version = try store.versions(of: listing.entry).last else {
      throw KagiError(.dataError, "\(listing.ref) 在库里没有任何版本的文件，可能还没同步下来。")
    }
    let file = try store.readEntry(listing.entry, version: version)
    guard file.vault == vault.vault else {
      throw KagiError(.dataError, "\(listing.ref) 的文件不属于这个库。")
    }
    let binding = Binding.entry(vault: vault.vault, entry: listing.entry, version: version, created: file.created)
    let plainData: Data
    do {
      plainData = try Crypto.open(file.box, key: key, binding: binding)
    } catch {
      throw KagiError(.dataError, "\(listing.ref) 的第 \(version) 版解不开，可能被改过。")
    }
    let plain = try JSON.decode(EntryPlain.self, from: plainData, file: "\(listing.ref) 第 \(version) 版")
    guard plain.ref == listing.ref, let value = Data(base64Encoded: plain.value) else {
      throw KagiError(.dataError, "\(listing.ref) 的第 \(version) 版里写的是别的条目，可能被调换过。")
    }
    return (version, value)
  }

  /// 存一个新版本。新条目从第 1 版开始；已有的条目在最新版本上加一，旧版本不删。
  @discardableResult
  public func write(
    ref: Ref, value: Data, issuer: String?, usedIn: String?, existing: Listing?, key: SymmetricKey
  ) throws -> Int {
    let entry = existing?.entry ?? Base32.encode(Crypto.randomBytes(10)).lowercased()
    let latest = try store.versions(of: entry).last ?? 0
    let version = latest + 1
    let created = Timestamp.now()
    let plain = try JSON.encode(EntryPlain(ref: ref.path, value: value.base64EncodedString()))
    let file = EntryFile(
      format: Format.entry, vault: vault.vault, entry: entry, version: version, created: created,
      box: try Crypto.seal(
        plain, key: key,
        binding: Binding.entry(vault: vault.vault, entry: entry, version: version, created: created)))
    try store.writeEntry(file)

    let record = IndexRecord(
      ref: ref.path, issuer: issuer ?? existing?.record.issuer, usedIn: usedIn ?? existing?.record.usedIn,
      created: existing?.record.created ?? created, updated: created, latestVersion: version)
    let indexKey = try indexKey()
    try store.writeIndex(
      IndexFile(
        format: Format.index, vault: vault.vault, entry: entry,
        box: try Crypto.seal(
          try JSON.encode(record), key: indexKey, binding: Binding.index(vault: vault.vault, entry: entry))))
    return version
  }

  public func devices() throws -> [DeviceFile] {
    try store.devices()
  }
}
