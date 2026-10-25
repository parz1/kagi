import Foundation

/// 库文件夹的读写。只管文件，不碰密钥。
///
///     <库>/vault.json
///     <库>/keys/<设备>.json
///     <库>/keys/recovery.json
///     <库>/entries/<条目>/<版本>.kagi
///     <库>/index/<条目>.kagi
public struct VaultStore: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  var vaultURL: URL { root.appendingPathComponent("vault.json") }
  var keysDir: URL { root.appendingPathComponent("keys", isDirectory: true) }
  var entriesDir: URL { root.appendingPathComponent("entries", isDirectory: true) }
  var indexDir: URL { root.appendingPathComponent("index", isDirectory: true) }
  var recoveryURL: URL { keysDir.appendingPathComponent("recovery.json") }

  public var exists: Bool { FileManager.default.fileExists(atPath: vaultURL.path) }

  // MARK: vault.json

  public func readVault() throws -> VaultFile {
    guard exists else {
      throw KagiError(.config, "\(root.path) 里没有 kagi 的库。")
    }
    let file: VaultFile = try read(vaultURL, "vault.json")
    guard file.format == Format.vault else {
      throw KagiError(.dataError, "vault.json 的格式版本是 \(file.format)，这个 kagi 认不得。")
    }
    return file
  }

  /// 新建库的所有文件。先写钥匙，最后写 vault.json，中途失败不会留下一个看起来完整的库。
  public func create(vault: VaultFile, device: DeviceFile, recovery: RecoveryFile) throws {
    guard !exists else {
      throw KagiError(.config, "\(root.path) 里已经有库了。", hint: "要让这台 Mac 加入它，用 kagi recover。")
    }
    for dir in [root, keysDir, entriesDir, indexDir] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try writeDevice(device)
    try write(recovery, to: recoveryURL)
    try write(vault, to: vaultURL)
  }

  // MARK: keys/

  public func writeDevice(_ device: DeviceFile) throws {
    try FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)
    try write(device, to: keysDir.appendingPathComponent("\(device.device).json"))
  }

  public func readDevice(_ id: String) throws -> DeviceFile {
    let url = keysDir.appendingPathComponent("\(id).json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw KagiError(
        .config, "库里没有这台 Mac（\(id)）的钥匙。",
        hint: "可能被别的设备移除了。用恢复密钥重新加入：kagi recover。")
    }
    let device: DeviceFile = try read(url, "keys/\(id).json")
    guard device.device == id else {
      throw KagiError(.dataError, "keys/\(id).json 里写的设备是 \(device.device)，文件可能被调换过。")
    }
    return device
  }

  public func devices() throws -> [DeviceFile] {
    try files(in: keysDir, suffix: ".json")
      .filter { $0.lastPathComponent != "recovery.json" }
      .map { url -> DeviceFile in try read(url, "keys/\(url.lastPathComponent)") }
      .sorted { $0.created < $1.created }
  }

  public func readRecovery() throws -> RecoveryFile {
    guard FileManager.default.fileExists(atPath: recoveryURL.path) else {
      throw KagiError(.dataError, "库里没有 keys/recovery.json，没法用恢复密钥。")
    }
    return try read(recoveryURL, "keys/recovery.json")
  }

  // MARK: entries/

  public func versions(of entry: String) throws -> [Int] {
    try files(in: entriesDir.appendingPathComponent(entry, isDirectory: true), suffix: ".kagi")
      .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
      .sorted()
  }

  public func readEntry(_ entry: String, version: Int) throws -> EntryFile {
    let name = "entries/\(entry)/\(Self.versionName(version))"
    let file: EntryFile = try read(entryURL(entry, version), name)
    guard file.entry == entry, file.version == version, file.format == Format.entry else {
      throw KagiError(.dataError, "\(name) 的内容和它的位置对不上，可能被调换过。")
    }
    return file
  }

  /// 写一个新版本。同名文件已经存在时报错，不覆盖。
  public func writeEntry(_ file: EntryFile) throws {
    let dir = entriesDir.appendingPathComponent(file.entry, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = entryURL(file.entry, file.version)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw KagiError(.software, "entries/\(file.entry)/\(Self.versionName(file.version)) 已经存在。")
    }
    try write(file, to: url)
  }

  func entryURL(_ entry: String, _ version: Int) -> URL {
    entriesDir.appendingPathComponent(entry, isDirectory: true)
      .appendingPathComponent(Self.versionName(version))
  }

  static func versionName(_ version: Int) -> String {
    String(format: "%04d.kagi", version)
  }

  // MARK: index/

  public func indexFiles() throws -> [IndexFile] {
    try files(in: indexDir, suffix: ".kagi").map { url -> IndexFile in
      let name = "index/\(url.lastPathComponent)"
      let file: IndexFile = try read(url, name)
      guard file.entry == url.deletingPathExtension().lastPathComponent, file.format == Format.index else {
        throw KagiError(.dataError, "\(name) 的内容和它的文件名对不上，可能被调换过。")
      }
      return file
    }
  }

  public func writeIndex(_ file: IndexFile) throws {
    try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
    try write(file, to: indexDir.appendingPathComponent("\(file.entry).kagi"))
  }

  // MARK: 文件

  func files(in dir: URL, suffix: String) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(suffix) && !$0.lastPathComponent.hasPrefix(".") }
  }

  func read<T: Decodable>(_ url: URL, _ name: String) throws -> T {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw KagiError(.dataError, "读不了 \(name)：\(error.localizedDescription)")
    }
    return try JSON.decode(T.self, from: data, file: name)
  }

  func write<T: Encodable>(_ value: T, to url: URL) throws {
    try JSON.encode(value).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
