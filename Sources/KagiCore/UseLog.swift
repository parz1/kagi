import Foundation

/// 使用记录的一行。从不记值。
public struct UseRecord: Codable, Equatable, Sendable {
  public var time: String
  public var action: String
  public var refs: [String]
  /// 交给子进程的命令（kagi run 的 -- 后面）。
  public var command: String?
  /// 发起者交给 shell 的整条命令，比如 agent 的原文。
  public var fullCommand: String?
  public var initiator: String
  public var chain: [String]
  /// approved、denied、locked、notFound、error
  public var result: String
  public var exitCode: Int32?

  static let fullCommandLimit = 2000

  public init(
    action: String, refs: [String], command: String?, fullCommand: String?, initiator: Initiator,
    result: String, exitCode: Int32? = nil
  ) {
    time = Timestamp.now()
    self.action = action
    self.refs = refs
    self.command = command
    // 整条命令可能是一大段脚本，只留开头。
    self.fullCommand = fullCommand.map { $0.count > Self.fullCommandLimit ? String($0.prefix(Self.fullCommandLimit)) + "…" : $0 }
    self.initiator = initiator.label
    chain = initiator.chain
    self.result = result
    self.exitCode = exitCode
  }
}

/// log.jsonl：每行一条 JSON，只追加。
public struct UseLog: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// 写一行。写不进去也不影响命令本身，只在 stderr 提一句。
  public func append(_ record: UseRecord) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var line = try encoder.encode(record)
      line.append(0x0A)
      if !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch {
      FileHandle.standardError.write(Data("kagi：使用记录写不进去（\(error.localizedDescription)）。\n".utf8))
    }
  }

  public func read() -> [UseRecord] {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
      return []
    }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { try? decoder.decode(UseRecord.self, from: Data($0.utf8)) }
  }
}
