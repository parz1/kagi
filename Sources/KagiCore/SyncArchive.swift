import CryptoKit
import Darwin
import Foundation

/// Only the existing recovery wraps and vault header are public; refs/metadata stay encrypted.
/// The authenticated header allows a new device to bootstrap using its recovery key alone.
struct SyncArchive: Codable {
  var format = "kagi-sync-archive/1"
  var vault: VaultFile
  var recovery: RecoveryFile
  var box: String

  private struct Header: Encodable {
    let format: String
    let vault: VaultFile
    let recovery: RecoveryFile
  }
  private func binding() throws -> Data {
    try JSON.encode(Header(format: format, vault: vault, recovery: recovery))
  }
  static func seal(_ snapshot: SyncSnapshot, key: SymmetricKey) throws -> Data {
    let vault = try JSON.decode(VaultFile.self, from: snapshot.files["vault.json"]!, file: "sync vault")
    let recovery = try JSON.decode(RecoveryFile.self, from: snapshot.files["keys/recovery.json"]!, file: "sync recovery")
    var archive = SyncArchive(vault: vault, recovery: recovery, box: "")
    archive.box = try Crypto.seal(try JSON.encode(snapshot), key: key, binding: archive.binding())
    return try JSON.encode(archive)
  }
  func open(key: SymmetricKey) throws -> SyncSnapshot {
    guard format == "kagi-sync-archive/1", vault.format == Format.vault,
      recovery.format == Format.recovery, recovery.vault == vault.vault else { throw KeyFailure.tampered }
    let bytes = try Crypto.open(box, key: key, binding: binding())
    let snapshot = try JSON.decode(SyncSnapshot.self, from: bytes, file: "sync snapshot")
    try Session.checkSyncPaths(snapshot.files)
    guard snapshot.format == "kagi-sync/1", snapshot.vault == vault.vault,
      try JSON.decode(VaultFile.self, from: snapshot.files["vault.json"]!, file: "vault") == vault,
      try JSON.encode(JSON.decode(RecoveryFile.self, from: snapshot.files["keys/recovery.json"]!, file: "recovery")) == JSON.encode(recovery)
    else { throw KeyFailure.tampered }
    return snapshot
  }
}

extension Kagi {
  /// New device: download a vault using its recovery key, then enroll its own device keys.
  /// The destination must not exist. No account or original-device private blob is needed.
  public static func recoverFromSync(
    with transport: SyncTransport, at destination: URL, recoveryKey: RecoveryKey,
    deviceName: String, backend: KeyBackend, local: LocalStore, reason: (String) -> String
  ) throws -> (vault: VaultFile, device: DeviceFile) {
    guard try local.load() == nil,
      !FileManager.default.fileExists(atPath: destination.path) else {
      throw KagiError(.config, "远端恢复需要尚未加入库的设备状态和不存在的目标目录。")
    }
    guard let id = try transport.head() else { throw KagiError(.notFound, "远端还没有同步快照。") }
    let bytes = try transport.object(id)
    guard SyncIO.hash(bytes) == id else { throw KeyFailure.tampered }
    let archive = try JSON.decode(SyncArchive.self, from: bytes, file: "sync archive")
    let secret = try Crypto.open(archive.recovery.secretWrap,
      key: recoveryKey.keyEncryptionKey(vault: archive.vault.vault),
      binding: Binding.recovery(vault: archive.vault.vault, purpose: .secret))
    let key = SymmetricKey(data: secret)
    guard Crypto.keyCheck(key, vault: archive.vault.vault, purpose: .secret) == archive.vault.keyCheck else {
      throw KeyFailure.tampered
    }
    let snapshot = try archive.open(key: key)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".kagi-join-" + UUID().uuidString)
    let temporaryLocal = destination.deletingLastPathComponent().appendingPathComponent(".kagi-join-local-" + UUID().uuidString)
    try SyncIO.directory(temporary)
    defer {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: temporaryLocal)
    }
    for (path, data) in snapshot.files {
      let url = temporary.appendingPathComponent(path)
      try SyncIO.directory(url.deletingLastPathComponent())
      try SyncIO.write(data, to: url)
    }
    for name in ["entries", "index", "keys"] { try SyncIO.directory(temporary.appendingPathComponent(name)) }
    let stagingLocal = LocalStore(dir: temporaryLocal)
    let joined = try recover(at: temporary, recoveryKey: recoveryKey, deviceName: deviceName,
      backend: backend, local: stagingLocal, reason: reason)
    let session = try Session(local: stagingLocal, backend: backend)
    try session.validateSyncSnapshot(snapshot, key: key)
    try session.saveSyncBaseline(transport: transport.identity, revision: id, key: key)
    try SyncIO.write(try JSON.encode(joined.device),
      to: temporary.appendingPathComponent("keys/" + joined.device.device + ".json"))
    guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw KagiError(.config, "无法发布恢复后的库，目标目录可能已经存在。")
    }
    try SyncIO.flushDirectory(destination.deletingLastPathComponent())
    var state = try requireDeviceState(stagingLocal)
    state.vaultPath = destination.path
    try local.save(state)
    return joined
  }
  private static func requireDeviceState(_ local: LocalStore) throws -> DeviceState {
    guard let state = try local.load() else { throw KagiError(.software, "缺少新设备状态。") }
    return state
  }
}
