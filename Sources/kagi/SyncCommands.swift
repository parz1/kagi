import Foundation
import KagiCore

extension Commands {
  static func sync(_ args: [String]) throws {
    var parser = ArgParser(args)
    let remote = try parser.value(for: "--remote")
    let json = parser.flag("--json")
    var resolutions: [String: SyncChoice] = [:]
    while let decision = try parser.value(for: "--resolve") {
      let parts = decision.split(separator: "=", omittingEmptySubsequences: false)
      guard parts.count == 2, let choice = SyncChoice(rawValue: String(parts[1])),
        resolutions[String(parts[0])] == nil else {
        throw KagiError(.usage, "冲突选择格式：--resolve <完整冲突 ID>=local|remote，不得重复。")
      }
      resolutions[String(parts[0])] = choice
    }
    try parser.finish()
    guard let remote, remote.hasPrefix("/") else {
      throw KagiError(.usage, "用法：kagi sync --remote <独立目录的绝对路径> [--json] [--resolve <ID>=local|remote]")
    }
    let session = try Session(local: localStore(), backend: backend())
    let root = URL(fileURLWithPath: remote).resolvingSymlinksInPath().standardizedFileURL
    let vault = session.store.root.resolvingSymlinksInPath().standardizedFileURL
    guard root.path != vault.path, !root.path.hasPrefix(vault.path + "/"),
      !vault.path.hasPrefix(root.path + "/") else {
      throw KagiError(.usage, "同步仓库与本地库必须使用互不包含的独立目录。")
    }
    let reason = "同步加密库到「\(root.path)」，应用 \(resolutions.count) 项冲突选择"
    guard Term.displayWidth(reason) <= 400,
      !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw KagiError(.usage, "同步目标路径太长或包含控制字符。")
    }
    var result: SyncResult!
    try managementWrite(session: session, action: "sync", refs: [],
      reason: reason) { key in
      let transport = try DirectorySyncTransport(root: root.appendingPathComponent(session.vault.vault))
      result = try session.synchronize(with: transport, key: key, resolutions: resolutions)
    }
    if json { try printJSON(result!) }
    else if result.conflicts.isEmpty {
      Term.print("库 ID：\(session.vault.vault)")
      Term.say(result.recovered ? "已恢复中断的同步；再次运行可继续检查远端。" : "同步完成。", .ok)
    } else {
      Term.say("发现冲突，本地库未修改。双方加密快照已保留：", .warn)
      for conflict in result.conflicts {
        Term.print("\(conflict.item)\n  \(conflict.id)")
        for (name, side) in [("本机", conflict.local), ("远端", conflict.remote)] {
          let keys = side.keys.map {
            "\($0.ref) v\($0.latestVersion) \($0.kind.rawValue) Space=\($0.metadata.space) archived=\($0.metadata.archived)"
          }
          let spaces = side.spaces.map { "Space \($0.id)=\($0.name)" }
          Term.print("  \(name)：\((keys + spaces).joined(separator: "；"))\(side.present ? "" : "不存在")")
        }
      }
      Term.say("核对后使用 --resolve <ID>=local 或 =remote；同一 key 的值和管理信息作为整体选择。")
    }
    if !result.conflicts.isEmpty {
      throw KagiError(.tempFail, "同步有未解决冲突。")
    }
  }
}
