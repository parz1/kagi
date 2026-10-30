import Foundation

/// 管理模型不依赖界面；Space 是组织维度，不是独立的加密或权限边界。
public struct KeyMetadata: Codable, Equatable, Sendable {
  public var title: String?
  public var space: String
  public var tags: [String]
  public var notes: String?
  public var archived: Bool

  public init(
    title: String? = nil, space: String = "default", tags: [String] = [],
    notes: String? = nil, archived: Bool = false
  ) {
    self.title = title
    self.space = space
    self.tags = tags
    self.notes = notes
    self.archived = archived
  }

  func normalized() throws -> KeyMetadata {
    try ManagementText.spaceID(space)
    let title = try ManagementText.optional(title, limit: 120)
    let notes = try ManagementText.optional(notes, limit: 4000, multiline: true)
    let tags = try ManagementText.tags(tags)
    return KeyMetadata(title: title, space: space, tags: tags, notes: notes, archived: archived)
  }
}

public struct SpaceRecord: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var created: String
  public var updated: String
}

public struct TagSummary: Codable, Equatable, Sendable {
  public var name: String
  public var count: Int
}

public enum KeyScope: String, Codable, Sendable {
  case active, archived, all
}

public struct KeyQuery: Sendable {
  public var space: String?
  public var tags: [String]
  public var text: String?
  public var scope: KeyScope

  public init(
    space: String? = nil, tags: [String] = [], text: String? = nil, scope: KeyScope = .active
  ) {
    self.space = space
    self.tags = tags
    self.text = text
    self.scope = scope
  }
}

struct CatalogFile: Codable {
  var format: String
  var vault: String
  var box: String
}

struct CatalogRecord: Codable {
  var spaces: [SpaceRecord]
}

enum ManagementText {
  static func spaceID(_ id: String) throws {
    _ = try Ref(id)
    guard !id.contains("/"), id.count <= 64 else {
      throw KagiError(.usage, "Space ID 使用单段小写引用，例如 personal 或 kotolog。")
    }
  }

  static func optional(_ value: String?, limit: Int, multiline: Bool = false) throws -> String? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard text.count <= limit,
      !text.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) && !(multiline && ($0 == "\n" || $0 == "\t"))
      })
    else { throw KagiError(.usage, "管理字段过长或包含不允许的控制字符。") }
    return text.isEmpty ? nil : text
  }

  static func tags(_ values: [String]) throws -> [String] {
    guard values.count <= 32 else { throw KagiError(.usage, "一条 key 最多 32 个标签。") }
    return try Set(
      values.map { value -> String in
        guard let tag = try optional(value, limit: 64) else { throw KagiError(.usage, "标签不能为空。") }
        return tag.lowercased()
      }
    ).sorted()
  }
}
