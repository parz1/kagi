import CryptoKit
import Darwin
import Foundation

/// Providers must durably publish immutable objects before atomically comparing/replacing the head.
/// A plain file upload (without conditional update) does not satisfy this contract.
public protocol SyncTransport {
  var identity: String { get }
  func head() throws -> String?
  func object(_ id: String) throws -> Data
  func put(_ data: Data) throws -> String
  func compareAndSwap(expected: String?, replacement: String) throws -> Bool
}

enum SyncIO {
  static let maxBytes = 64 * 1024 * 1024
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func validID(_ id: String) -> Bool {
    id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func directory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      let parent = url.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: parent.path) { try directory(parent) }
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try flushDirectory(parent)
    }
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw KagiError(.dataError, "同步目录不能是符号链接或普通文件。")
    }
  }
  static func read(_ url: URL, limit: Int = maxBytes) throws -> Data {
    // O_NOFOLLOW also protects the final component against a symlink substitution.
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw KagiError(.dataError, "无法读取同步文件。") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= 0, info.st_size <= limit else {
      throw KagiError(.dataError, "同步文件类型或大小无效。")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit, data.count == Int(info.st_size) else {
      throw KagiError(.dataError, "同步文件在读取期间变化或超过大小限制。")
    }
    return data
  }
  static func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw KagiError(.software, "无法持久化同步文件。") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw KagiError(.software, "无法持久化同步文件。") }
    try flushDirectory(url.deletingLastPathComponent())
  }
  static func flushDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw KagiError(.software, "无法持久化同步目录。") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw KagiError(.software, "无法持久化同步目录。") }
  }
  static func move(_ source: URL, to destination: URL) throws {
    guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw KagiError(.software, "无法保留旧条目的未完成写入文件。")
    }
    try flushDirectory(source.deletingLastPathComponent())
    try flushDirectory(destination.deletingLastPathComponent())
  }
  static func remove(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
    try flushDirectory(url.deletingLastPathComponent())
  }
}

/// Reference adapter for a local test server/directory, not for a cloud client's mirrored directory.
/// Its flock/CAS is only valid when all clients access this same filesystem lock.
public struct DirectorySyncTransport: SyncTransport {
  public let root: URL
  public var identity: String { root.resolvingSymlinksInPath().standardizedFileURL.path }

  public init(root: URL) throws {
    self.root = root.standardizedFileURL
    try SyncIO.directory(self.root)
    try SyncIO.directory(self.root.appendingPathComponent("objects"))
  }
  private var headURL: URL { root.appendingPathComponent("HEAD") }
  public func head() throws -> String? {
    guard FileManager.default.fileExists(atPath: headURL.path) else { return nil }
    let text = String(decoding: try SyncIO.read(headURL, limit: 64), as: UTF8.self)
    guard SyncIO.validID(text) else { throw KagiError(.dataError, "远端 HEAD 无效。") }
    return text
  }
  public func object(_ id: String) throws -> Data {
    guard SyncIO.validID(id) else { throw KagiError(.dataError, "同步对象 ID 无效。") }
    let data = try SyncIO.read(root.appendingPathComponent("objects/" + id))
    guard SyncIO.hash(data) == id else { throw KagiError(.dataError, "同步对象校验失败。") }
    return data
  }
  public func put(_ data: Data) throws -> String {
    guard data.count <= SyncIO.maxBytes else { throw KagiError(.usage, "同步快照超过 64 MiB 限制。") }
    let id = SyncIO.hash(data)
    return try locked {
      let url = root.appendingPathComponent("objects/" + id)
      if FileManager.default.fileExists(atPath: url.path) { _ = try object(id) }
      else { try SyncIO.write(data, to: url) }
      return id
    }
  }
  public func compareAndSwap(expected: String?, replacement: String) throws -> Bool {
    _ = try object(replacement)
    return try locked {
      guard try head() == expected else { return false }
      try SyncIO.write(Data(replacement.utf8), to: headURL)
      return true
    }
  }
  private func locked<T>(_ body: () throws -> T) throws -> T {
    let fd = open(root.appendingPathComponent(".lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw KagiError(.software, "无法打开远端锁。") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw KagiError(.software, "无法锁定远端。") }
    defer { _ = flock(fd, LOCK_UN) }
    return try body()
  }
}
