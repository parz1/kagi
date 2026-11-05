import CryptoKit
import Foundation
import KagiCore

extension Commands {
  static func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    Term.print(String(decoding: try encoder.encode(value), as: UTF8.self))
  }

  static func managementWrite(
    session: Session, action: String, refs: [String], reason: String, access: Kagi.Action = .write,
    operation: (SymmetricKey) throws -> Void
  ) throws {
    let initiator = Initiator.current()
    do {
      let key = try session.unlock(
        reason: reason + "（\(Reason.by(initiator))）", action: access,
        byAgent: initiator.isAgent)
      try operation(key)
      useLog().append(
        UseRecord(
          action: action, refs: refs, command: nil, fullCommand: nil,
          initiator: initiator, result: "approved"))
    } catch {
      let code = (error as? KagiError)?.code ?? .software
      useLog().append(
        UseRecord(
          action: action, refs: refs, command: nil, fullCommand: nil,
          initiator: initiator,
          result: (error as? KagiError)?.auditResult ?? "error",
          exitCode: code.rawValue))
      throw error
    }
  }

  static func space(_ args: [String]) throws {
    let action = args.first ?? "ls"
    var parser = ArgParser(Array(args.dropFirst()))
    let json = parser.flag("--json")
    let name = try parser.value(for: "--name")
    let positional = try parser.positionals()
    let session = try Session(local: localStore(), backend: backend())
    if action == "ls" {
      guard positional.isEmpty, name == nil else {
        throw KagiError(.usage, "用法：kagi space ls [--json]")
      }
      let records = try session.spaces()
      if json {
        try printJSON(records)
        return
      }
      let items = try session.listings(includeArchived: true)
      printTable(
        header: ["Space ID", "名称", "key 数（含归档）"],
        rows: records.map { record in
          [
            record.id, record.name,
            String(items.filter { $0.record.metadata.space == record.id }.count),
          ]
        })
      return
    }
    guard positional.count == 1, ["create", "rename", "remove"].contains(action), !json else {
      throw KagiError(
        .usage, "用法：kagi space create <ID> [--name <名称>]；rename <ID> --name <名称>；remove <ID>")
    }
    let id = try Ref(positional[0]).path
    guard !id.contains("/"), id.count <= 64 else { throw KagiError(.usage, "Space ID 必须是单段引用。") }
    if action == "rename", name == nil { throw KagiError(.usage, "rename 需要 --name <名称>。") }
    if action == "remove", name != nil { throw KagiError(.usage, "remove 不接受 --name。") }
    try managementWrite(
      session: session, action: "space-" + action, refs: [], reason: "\(action) Space「\(id)」"
    ) { key in
      switch action {
      case "create": try session.createSpace(id: id, name: name ?? id, key: key)
      case "rename": try session.renameSpace(id: id, name: name!, key: key)
      default: try session.removeSpace(id: id, key: key)
      }
    }
    Term.say("Space \(id)：\(action) 完成。", .ok)
  }

  static func edit(_ args: [String]) throws {
    var parser = ArgParser(args)
    let title = try parser.value(for: "--title")
    let space = try parser.value(for: "--space")
    let notes = try parser.value(for: "--notes")
    let issuer = try parser.value(for: "--issuer")
    let usedIn = try parser.value(for: "--used-in")
    var tags: [String] = []
    while let tag = try parser.value(for: "--tag") { tags.append(tag) }
    let clearTitle = parser.flag("--clear-title")
    let clearTags = parser.flag("--clear-tags")
    let clearNotes = parser.flag("--clear-notes")
    let clearIssuer = parser.flag("--clear-issuer")
    let clearUsedIn = parser.flag("--clear-used-in")
    let positional = try parser.positionals()
    guard positional.count == 1,
      !(clearTitle && title != nil), !(clearTags && !tags.isEmpty), !(clearNotes && notes != nil),
      !(clearIssuer && issuer != nil), !(clearUsedIn && usedIn != nil)
    else {
      throw KagiError(
        .usage,
        "用法：kagi edit <引用> [--title ...] [--space ...] [--tag ...] [--notes ...]；设置与清空同一字段不能一起使用。")
    }
    guard
      title != nil || space != nil || notes != nil || issuer != nil || usedIn != nil
        || !tags.isEmpty
        || clearTitle || clearTags || clearNotes || clearIssuer || clearUsedIn
    else {
      throw KagiError(.usage, "请指定至少一个要更新或清空的字段。")
    }
    let ref = try Ref(positional[0])
    let session = try Session(local: localStore(), backend: backend())
    guard let item = try session.find(ref, includeArchived: true) else {
      throw notFound(ref.path, among: [])
    }
    var metadata = item.record.metadata
    if let title { metadata.title = title }
    if let space { metadata.space = space }
    if let notes { metadata.notes = notes }
    if !tags.isEmpty { metadata.tags = tags }
    if clearTitle { metadata.title = nil }
    if clearTags { metadata.tags = [] }
    if clearNotes { metadata.notes = nil }
    try managementWrite(
      session: session, action: "edit", refs: [ref.path], reason: "更新「\(ref.path)」的管理信息，保留值与引用"
    ) { key in
      try session.updateKey(
        item, metadata: metadata,
        issuer: clearIssuer ? nil : issuer ?? item.record.issuer,
        usedIn: clearUsedIn ? nil : usedIn ?? item.record.usedIn, key: key)
    }
    Term.say("已更新 \(ref.path) 的管理信息，值与引用保持有效。", .ok)
  }

  static func archive(_ args: [String], archived: Bool) throws {
    var parser = ArgParser(args)
    let positional = try parser.positionals()
    guard positional.count == 1 else {
      throw KagiError(.usage, "用法：kagi \(archived ? "archive" : "restore") <引用>")
    }
    let ref = try Ref(positional[0])
    let session = try Session(local: localStore(), backend: backend())
    guard let item = try session.find(ref, includeArchived: true) else {
      throw notFound(ref.path, among: [])
    }
    guard item.record.metadata.archived != archived else {
      Term.say(archived ? "此 key 已归档。" : "此 key 已处于可用状态。")
      return
    }
    var metadata = item.record.metadata
    metadata.archived = archived
    try managementWrite(
      session: session, action: archived ? "archive" : "restore", refs: [ref.path],
      reason: "\(archived ? "归档" : "恢复")「\(ref.path)」，保留历史版本"
    ) { key in
      try session.updateKey(
        item, metadata: metadata, issuer: item.record.issuer, usedIn: item.record.usedIn, key: key)
    }
    Term.say(archived ? "已归档 \(ref.path)。" : "已恢复 \(ref.path)。", .ok)
  }

  static func tags(_ args: [String]) throws {
    var parser = ArgParser(args)
    let all = parser.flag("--all")
    let json = parser.flag("--json")
    try parser.finish()
    let session = try Session(local: localStore(), backend: backend())
    let records = try session.tags(includeArchived: all)
    if json {
      try printJSON(records)
      return
    }
    printTable(header: ["标签", "key 数"], rows: records.map { [$0.name, String($0.count)] })
  }
}
