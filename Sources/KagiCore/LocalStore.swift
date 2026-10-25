import Foundation

/// 这台 Mac 自己的状态，不进网盘：库在哪、设备 ID、两把设备密钥的 blob，以及记下的库密钥校验值。
public struct DeviceState: Codable, Equatable, Sendable {
  public var format: String
  public var vaultPath: String
  public var vault: String
  public var device: String
  public var created: String
  /// 加入库时记下的校验值。网盘上的 vault.json 或钥匙被人换掉时，靠它发现。
  public var keyCheck: String
  public var indexKeyCheck: String
  public var secretKeyBlob: String
  public var indexKeyBlob: String
}

/// ~/Library/Application Support/kagi/：device.json 和使用记录 log.jsonl，目录权限 0700，文件 0600。
public struct LocalStore: Sendable {
  public let dir: URL

  public init(dir: URL) {
    self.dir = dir
  }

  public static func standard() -> LocalStore {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return LocalStore(dir: support.appendingPathComponent("kagi", isDirectory: true))
  }

  var stateURL: URL { dir.appendingPathComponent("device.json") }
  public var logURL: URL { dir.appendingPathComponent("log.jsonl") }

  public func load() throws -> DeviceState? {
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
    let data = try Data(contentsOf: stateURL)
    return try JSON.decode(DeviceState.self, from: data, file: stateURL.path)
  }

  public func save(_ state: DeviceState) throws {
    try ensureDir()
    try JSON.encode(state).write(to: stateURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }

  func ensureDir() throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
  }
}
