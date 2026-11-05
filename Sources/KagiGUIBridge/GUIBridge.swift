import AppKit
import CryptoKit
import Foundation
import KagiCore

/// Serialized by the macOS host queue. No arbitrary command/path-to-vault execution surface.
/// Raw secret values, recovery keys and device blobs are never returned over the GUI channel.
public final class GUIBridge {
  private let local: LocalStore
  private let backend: KeyBackend
  private let mode: String
  private let copy: (String) -> Void
  private var locked = true

  public init(local: LocalStore = .standard(), backend: KeyBackend = SecureEnclaveBackend(),
    mode: String = "native", copy: ((String) -> Void)? = nil) {
    self.local = local
    self.backend = backend
    self.mode = mode
    self.copy = copy ?? Self.copyToPasteboard
  }

  public func handle(_ bytes: Data) -> Data {
    do {
      guard bytes.count <= 1024 * 1024,
        let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        Set(request.keys).isSubset(of: ["version", "method", "arguments"]),
        request["version"] as? Int == 1, let method = request["method"] as? String,
        let args = request["arguments"] as? [String: Any] else {
        throw KagiError(.usage, "GUI 请求格式或协议版本无效。")
      }
      let allowed: [String: Set<String>] = [
        "snapshot": [], "lock": [], "unlock": [],
        "create": ["ref", "value", "kind", "metadata"],
        "update": ["ref", "revision", "metadata"],
        "copySecret": ["ref", "revision"], "totp": ["ref", "revision"],
        "space": ["action", "id", "name"], "sync": ["remotePath", "resolutions"],
      ]
      guard let fields = allowed[method], Set(args.keys).isSubset(of: fields) else {
        throw KagiError(.usage, "不支持的 GUI 操作或参数。")
      }
      let result = try perform(method, args)
      return try JSONSerialization.data(withJSONObject: ["version": 1, "result": result], options: [.sortedKeys])
    } catch {
      let failure = error as? KagiError
      let code = failure?.code.rawValue ?? ExitCode.dataError.rawValue
      if code == ExitCode.tempFail.rawValue || code == ExitCode.config.rawValue { locked = true }
      // Never serialize arbitrary errors: native APIs may embed input or filesystem details.
      return (try? JSONSerialization.data(withJSONObject: ["version": 1, "error": [
        "code": code, "message": failure?.message ?? "核心操作失败，请检查库完整性后重试。",
      ]], options: [.sortedKeys])) ?? Data()
    }
  }

  private func perform(_ method: String, _ args: [String: Any]) throws -> [String: Any] {
    if method == "lock" { locked = true; return ["locked": true] }
    if method == "snapshot" {
      guard try local.load() != nil else {
        return ["mode": mode, "status": "unconfigured", "spaces": [], "keys": []]
      }
      guard !locked else { return ["mode": mode, "status": "locked", "spaces": [], "keys": []] }
    }
    let session = try Session(local: local, backend: backend)
    if method == "unlock" {
      _ = try authorize(session, action: "unlock", ref: nil, access: .read)
      locked = false
      return try snapshot(session)
    }
    guard !locked else { throw KagiError(.tempFail, "保险库已锁定，请先解锁。") }
    switch method {
    case "snapshot": return try snapshot(session)
    case "create":
      let ref = try Ref(string(args, "ref"))
      guard try session.find(ref, includeArchived: true) == nil else {
        throw KagiError(.usage, "此引用已存在，请使用新的引用。")
      }
      let value = try string(args, "value")
      guard value.utf8.count <= 65536 else { throw KagiError(.usage, "GUI 单次导入最多 64 KiB。") }
      let metadata = try decodeMetadata(args)
      let kind = try string(args, "kind")
      guard ["secret", "totp"].contains(kind) else { throw KagiError(.usage, "此版本 GUI 支持普通密钥和 TOTP 导入。") }
      let credential = kind == "totp" ? try TOTPCredential.parse(value) : nil
      let key = try authorize(session, action: "create", ref: ref.path)
      if let credential { try session.importTOTP(ref: ref, credential: credential, metadata: metadata, key: key) }
      else { try session.write(ref: ref, value: Data(value.utf8), issuer: nil, usedIn: nil,
        existing: nil, key: key, metadata: metadata) }
      return try snapshot(session)
    case "update":
      let item = try expectedItem(session, args)
      let metadata = try decodeMetadata(args)
      let key = try authorize(session, action: "update", ref: item.ref)
      try session.updateKey(item, metadata: metadata, issuer: item.record.issuer,
        usedIn: item.record.usedIn, key: key)
      return try snapshot(session)
    case "copySecret":
      let item = try expectedItem(session, args)
      guard item.record.kind == .secret else { throw KagiError(.usage, "验证器种子与私钥不能复制。") }
      let key = try authorize(session, action: "copy", ref: item.ref, access: .read)
      let value = try session.read(item, key: key).value
      guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else {
        throw KagiError(.usage, "此二进制密钥无法复制为文本。")
      }
      copy(text)
      return ["copied": true, "clearAfter": 30]
    case "totp":
      let item = try expectedItem(session, args)
      guard item.record.kind == .totp else { throw KagiError(.usage, "此条目不是 TOTP。") }
      let key = try authorize(session, action: "totp", ref: item.ref, access: .read)
      return try object(session.totpCode(item, at: UInt64(Date().timeIntervalSince1970), key: key))
    case "space":
      let action = try string(args, "action"), id = try string(args, "id")
      guard ["create", "rename", "remove"].contains(action) else { throw KagiError(.usage, "不支持的 Space 操作。") }
      let key = try authorize(session, action: "space-" + action, ref: id)
      if action == "create" { try session.createSpace(id: id, name: string(args, "name"), key: key) }
      else if action == "rename" { try session.renameSpace(id: id, name: string(args, "name"), key: key) }
      else { try session.removeSpace(id: id, key: key) }
      return try snapshot(session)
    case "sync":
      let path = try string(args, "remotePath")
      guard path.hasPrefix("/"), path.count <= 300,
        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw KagiError(.usage, "同步需要不含控制字符的绝对目录路径。")
      }
      let remote = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      let vault = session.store.root.resolvingSymlinksInPath().standardizedFileURL
      guard remote.path != vault.path, !remote.path.hasPrefix(vault.path + "/"),
        !vault.path.hasPrefix(remote.path + "/") else { throw KagiError(.usage, "同步目标与库目录不能互相包含。") }
      let selections: [String: String]
      if let raw = args["resolutions"] {
        guard let values = raw as? [String: String] else { throw KagiError(.usage, "冲突选择格式无效。") }
        selections = values
      } else { selections = [:] }
      guard selections.count <= 128 else { throw KagiError(.usage, "冲突选择过多。") }
      var choices: [String: SyncChoice] = [:]
      for (id, text) in selections {
        guard let choice = SyncChoice(rawValue: text) else { throw KagiError(.usage, "无效的冲突选择。") }
        choices[id] = choice
      }
      let key = try authorize(session, action: "sync", ref: nil, detail: remote.path)
      let transport = try DirectorySyncTransport(root: remote.appendingPathComponent(session.vault.vault))
      let result = try session.synchronize(with: transport, key: key, resolutions: choices)
      return ["sync": try object(result), "snapshot": try snapshot(session)]
    default: throw KagiError(.usage, "不支持的 GUI 操作。")
    }
  }

  private func snapshot(_ session: Session) throws -> [String: Any] {
    if FileManager.default.fileExists(atPath: session.store.root.appendingPathComponent(".sync-pending").path) {
      return ["mode": mode, "status": "syncRecovery", "spaces": [], "keys": [],
        "capabilities": ["directorySync": true]]
    }
    return ["mode": mode, "status": "ready", "vaultID": session.vault.vault,
      "spaces": try array(session.spaces()), "keys": try array(session.listings(includeArchived: true)),
      "capabilities": ["manage": true, "copySecret": true, "totp": true,
        "passkeyProvider": false, "directorySync": true]]
  }
  private func expectedItem(_ session: Session, _ args: [String: Any]) throws -> Listing {
    let ref = try Ref(string(args, "ref")), revision = try string(args, "revision")
    guard let item = try session.find(ref, includeArchived: true) else { throw KagiError(.notFound, "条目不存在，请刷新。") }
    guard item.revision == revision else { throw KagiError(.tempFail, "条目已变化，请刷新后重新操作。") }
    return item
  }
  private func decodeMetadata(_ args: [String: Any]) throws -> KeyMetadata {
    guard let metadata = args["metadata"] as? [String: Any],
      Set(metadata.keys).isSubset(of: ["title", "space", "tags", "notes", "archived"]) else {
      throw KagiError(.usage, "管理字段无效。")
    }
    do { return try JSONDecoder().decode(KeyMetadata.self, from: JSONSerialization.data(withJSONObject: metadata)) }
    catch { throw KagiError(.usage, "管理字段无效。") }
  }
  private func string(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.isEmpty else { throw KagiError(.usage, "缺少必填字段。") }
    return value
  }
  private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
  }
  private func array<T: Encodable>(_ value: T) throws -> [Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [Any]
  }
  private func authorize(_ session: Session, action: String, ref: String?, access: Kagi.Action = .write,
    detail: String? = nil) throws -> SymmetricKey {
    let initiator = Initiator(label: "Kagi GUI", isAgent: false, chain: ["kagi-gui"], shellCommand: nil)
    let reason = "Kagi GUI：\(action)\(ref.map { "「" + $0 + "」" } ?? "")\(detail.map { "，目标「" + $0 + "」" } ?? "")"
    guard reason.unicodeScalars.reduce(0, { $0 + ($1.isASCII ? 1 : 2) }) <= 500,
      !reason.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw KagiError(.usage, "授权说明过长或含控制字符。")
    }
    do {
      let key = try session.unlock(reason: reason, action: access, byAgent: false)
      UseLog(url: local.logURL).append(UseRecord(action: "gui-authorize-" + action, refs: ref.map { [$0] } ?? [],
        command: nil, fullCommand: nil, initiator: initiator, result: "approved"))
      return key
    } catch {
      let code = (error as? KagiError)?.code ?? .software
      UseLog(url: local.logURL).append(UseRecord(action: "gui-authorize-" + action, refs: ref.map { [$0] } ?? [],
        command: nil, fullCommand: nil, initiator: initiator,
        result: (error as? KagiError)?.auditResult ?? "error", exitCode: code.rawValue))
      throw error
    }
  }
  private static func copyToPasteboard(_ value: String) {
    // 与 CLI 一致：只留在本机（不进通用剪贴板），并标记为隐藏、临时，剪贴板管理器不应记录。
    let write = {
      let board = NSPasteboard.general
      board.prepareForNewContents(with: .currentHostOnly)
      board.setString(value, forType: .string)
      board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
      board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
      let generation = board.changeCount
      _ = ClipboardLease(generation: generation, currentGeneration: { board.changeCount },
        erase: { board.clearContents() })
    }
    if Thread.isMainThread { write() } else { DispatchQueue.main.sync(execute: write) }
  }
}
