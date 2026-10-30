import CryptoKit
import Foundation
import KagiCore
import SystemConfiguration

/// 指纹框里的说明。系统会在前面加上「kagi is trying to」，所以动词放在最前面。
enum Reason {
  static let commandWidth = 120

  static func by(_ initiator: Initiator) -> String {
    initiator.label + (initiator.label.last?.isASCII == true ? " 发起" : "发起")
  }

  static func run(injections: [String], command: String, directory: String, initiator: Initiator)
    throws -> String
  {
    let reason =
      "交给命令「\(command)」；目录「\(directory)」；\(injections.joined(separator: "、"))（\(by(initiator))）"
    guard Term.displayWidth(reason) <= 500,
      !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw KagiError(.usage, "授权说明太长或包含控制字符，命令没有运行。请减少本次请求的条目或缩短命令。")
    }
    return reason
  }

  static func set(ref: String, overwriting version: Int?, fromStdin: Bool, initiator: Initiator)
    -> String
  {
    let what = fromStdin ? "把标准输入存为 \(ref)" : "存入 \(ref)"
    if let version {
      let verb = fromStdin ? "把标准输入存为 \(ref)，覆盖旧值" : "覆盖 \(ref)"
      return "\(verb)，旧值保留为第 \(version) 版（\(by(initiator))）"
    }
    return "\(what)（新建，\(by(initiator))）"
  }
}

enum Commands {
  // MARK: 环境

  static func backend() throws -> KeyBackend {
    #if DEBUG
      if ProcessInfo.processInfo.environment["KAGI_DEBUG_SOFTWARE_KEYS"] == "1" {
        let name = ProcessInfo.processInfo.environment["KAGI_DEBUG_AUTH_DECISION"] ?? "approve"
        let decision: SoftwareBackend.Decision
        switch name {
        case "approve": decision = .approve
        case "deny": decision = .deny
        case "locked": decision = .locked
        default:
          throw KagiError(.usage, "KAGI_DEBUG_AUTH_DECISION 只能是 approve、deny 或 locked。")
        }
        Term.say("（调试版：软件密钥，模拟验证结果：\(name)，不弹真实指纹框）", .warn)
        return SoftwareBackend(decision: decision) { reason in
          Term.say("模拟授权说明：\(reason)", .dim)
        }
      }
    #endif
    return SecureEnclaveBackend()
  }

  static func localStore() -> LocalStore {
    #if DEBUG
      if let home = ProcessInfo.processInfo.environment["KAGI_HOME"] {
        return LocalStore(dir: URL(fileURLWithPath: home, isDirectory: true))
      }
    #endif
    return .standard()
  }

  /// 「系统设置 › 通用 › 共享」里的电脑名。不用 Host.current()，它可能做网络解析，卡好几秒。
  static func computerName() -> String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
  }

  static func useLog() -> UseLog {
    UseLog(url: localStore().logURL)
  }

  /// Local-first: cloud providers are explicit transports, never a required account.
  static func defaultVaultRoot() throws -> URL {
    localStore().dir.appendingPathComponent("vault", isDirectory: true)
  }

  static func vaultRoot(_ option: String?) throws -> URL {
    if let option {
      return URL(fileURLWithPath: (option as NSString).expandingTildeInPath, isDirectory: true)
    }
    return try defaultVaultRoot()
  }

  static func requireTerminal(_ command: String, _ why: String, initiator: Initiator) throws {
    guard Term.stdinIsTTY, Term.stdoutIsTTY, !initiator.isAgent else {
      throw KagiError(.usage, "kagi \(command) 要在你自己的终端里运行（\(why)）。")
    }
  }

  // MARK: init

  static func initVault(_ args: [String]) throws {
    var parser = ArgParser(args)
    let vaultOption = try parser.value(for: "--vault")
    try parser.finish()

    let initiator = Initiator.current()
    try requireTerminal("init", "会显示恢复密钥", initiator: initiator)
    let local = localStore()
    if let state = try local.load() {
      throw KagiError(.config, "这台 Mac 已经在库 \(Kagi.shortID(state.vault)) 里了（\(state.vaultPath)）。")
    }
    let root = try vaultRoot(vaultOption)
    Term.print("库的位置：\(root.path)")
    Term.print("（库里的文件都是加密的。换位置用 --vault <路径>）", .dim)
    Term.print("")
    Term.print("先确认这台 Mac 能用指纹解锁 kagi。")
    Term.print("等待指纹确认…", .dim)

    let pending = try Kagi.prepareInit(
      at: root, deviceName: computerName(), backend: backend(),
      reason: { "确认这台 Mac 能用指纹解锁 kagi（新建库 \($0)）" })
    let short = Kagi.shortID(pending.vault.vault)
    Term.print("已创建这台 Mac 的设备密钥 \(pending.device.device)（在 Secure Enclave 里）", .ok)
    Term.print("")
    Term.print("恢复密钥（只显示这一次）：", .bold)
    Term.print("")
    Term.print("    \(pending.recoveryKey.displayText)", .bold)
    Term.print("")
    Term.print("请现在做两件事：")
    Term.print("  1. 抄在纸上，收好。")
    Term.print("  2. 在「密码」App 里新建一条「kagi 恢复密钥」，存进去。")
    Term.print("这台 Mac 丢了或坏了，只能靠它找回库。kagi 不保存它，也不会再显示。", .dim)

    let copy = Term.readVisible("要复制到剪贴板吗？30 秒后自动清除，并标记为「隐藏、只在本机」。[y/N] ") ?? ""
    if copy.lowercased().hasPrefix("y") {
      if Clipboard.copyConcealed(pending.recoveryKey.displayText, clearAfter: 30) {
        Term.print("已复制，30 秒后清除。", .ok)
      } else {
        Term.print("复制没成功，请手抄。", .warn)
      }
    }

    let expected = normalize(pending.recoveryKey.lastGroup)
    var confirmed = false
    for attempt in 1...3 {
      let typed = Term.readVisible("为确认你已经记下，请输入最后一组：") ?? ""
      if normalize(typed) == expected {
        confirmed = true
        break
      }
      if attempt < 3 { Term.print("不对，再看一眼抄下来的最后一组。", .warn) }
    }
    guard confirmed else {
      throw KagiError(.usage, "最后一组对不上，库没有建。", hint: "重新运行 kagi init，会生成新的恢复密钥。")
    }
    Term.print("对了。", .ok)

    try pending.commit(local: local)
    useLog().append(
      UseRecord(
        action: "init", refs: [], command: nil, fullCommand: nil, initiator: initiator,
        result: "approved"))
    Term.print("")
    Term.print("完成。库 \(short) 已建好。下一步：", .ok)
    Term.print("  kagi set <引用>     存一条密钥，比如 kagi set resend/api-key")
    Term.print("  kagi guide         给 agent 看的用法说明")
  }

  #if DEBUG
    /// 只在调试版里有：不问不确认，用软件密钥建一个假库，给开发时跑命令用。
    static func debugInit(_ args: [String]) throws {
      var parser = ArgParser(args)
      let vaultOption = try parser.value(for: "--vault")
      try parser.finish()
      guard ProcessInfo.processInfo.environment["KAGI_DEBUG_SOFTWARE_KEYS"] == "1" else {
        throw KagiError(.usage, "_debug-init 只能和 KAGI_DEBUG_SOFTWARE_KEYS=1 一起用。")
      }
      let pending = try Kagi.prepareInit(
        at: try vaultRoot(vaultOption), deviceName: "调试", backend: backend(), reason: { $0 })
      try pending.commit(local: localStore())
      Term.print(
        "调试库 \(Kagi.shortID(pending.vault.vault)) 已建好。恢复密钥（调试库，假的）：\(pending.recoveryKey.displayText)"
      )
    }
  #endif

  static func normalize(_ group: String) -> String {
    group.uppercased().filter { $0 != "-" && $0 != " " }
      .replacingOccurrences(of: "O", with: "0")
      .replacingOccurrences(of: "I", with: "1")
      .replacingOccurrences(of: "L", with: "1")
  }

  // MARK: set

  static func set(_ args: [String]) throws {
    var parser = ArgParser(args)
    let fromStdin = parser.flag("--stdin")
    let raw = parser.flag("--raw")
    let issuer = try parser.value(for: "--issuer")
    let usedIn = try parser.value(for: "--used-in")
    let space = try parser.value(for: "--space")
    let title = try parser.value(for: "--title")
    var tags: [String] = []
    while let tag = try parser.value(for: "--tag") { tags.append(tag) }
    let positional = try parser.positionals()
    guard positional.count == 1 else {
      throw KagiError(.usage, "用法：kagi set <引用> [--stdin] [--issuer <签发方>] [--used-in <用在哪>]")
    }
    let ref = try Ref(positional[0])
    let initiator = Initiator.current()
    let session = try Session(local: localStore(), backend: backend())
    let existing = try session.find(ref, includeArchived: true)
    guard existing == nil || existing?.record.kind == .secret else {
      throw KagiError(.usage, "该引用是验证器凭据，不能用普通 set 覆盖。")
    }
    guard existing?.record.metadata.archived != true else {
      throw KagiError(.usage, "此 key 已归档，请先用 kagi restore 恢复。")
    }
    var metadata = existing?.record.metadata ?? KeyMetadata()
    if let space { metadata.space = space }
    if let title { metadata.title = title }
    if !tags.isEmpty { metadata.tags = tags }

    if let existing {
      Term.say(
        "\(ref) 已有第 \(existing.record.latestVersion) 版（\(Term.shortTime(existing.record.updated)) 存入）。"
          + "新值会成为第 \(existing.record.latestVersion + 1) 版，旧值保留。")
    }

    var value: Data
    if fromStdin {
      value = FileHandle.standardInput.readDataToEndOfFile()
      if !raw {
        if value.last == 0x0A { value.removeLast() }
        if value.last == 0x0D { value.removeLast() }
      }
    } else {
      guard Term.stdinIsTTY, let typed = Term.readHidden("值（输入时不显示）：") else {
        throw KagiError(.usage, "这里没有终端可以输入值。", hint: "从管道传进来：… | kagi set \(ref) --stdin")
      }
      // 终端输入有长度上限，超长的会被截断；长的、多行的值从标准输入传。
      guard typed.utf8.count < Term.inputLimit - 1 else {
        throw KagiError(
          .usage, "值太长，终端输入放不下，什么都没存。", hint: "从管道或文件传进来：kagi set \(ref) --stdin < 文件")
      }
      value = Data(typed.utf8)
    }
    guard !value.isEmpty else {
      throw KagiError(.usage, "值是空的，什么都没存。")
    }
    if let shell = initiator.shellCommand, let text = String(data: value, encoding: .utf8),
      text.count >= Redactor.minimumLength, shell.contains(text)
    {
      Term.say("注意：这个值直接写在了命令行里，会留在 shell 历史和 agent 的记录里。下次让它从文件或上一个命令的输出流进来。", .warn)
    }

    let auditRedactor = Redactor(values: [(ref.path, value)], minimumLength: 1)
    Term.say("等待指纹确认…", .dim)
    let reason = Reason.set(
      ref: ref.path, overwriting: existing?.record.latestVersion, fromStdin: fromStdin,
      initiator: initiator)
    let key: SymmetricKey
    do {
      key = try session.unlock(reason: reason, action: .write, byAgent: initiator.isAgent)
    } catch let error as KagiError {
      useLog().append(
        UseRecord(
          action: "set", refs: [ref.path], command: nil,
          fullCommand: initiator.shellCommand.map(auditRedactor.redact),
          initiator: initiator,
          result: error.code == .denied ? "denied" : error.code == .tempFail ? "locked" : "error"))
      throw error
    }
    let version = try session.write(
      ref: ref, value: value, issuer: issuer, usedIn: usedIn, existing: existing, key: key,
      metadata: metadata)
    useLog().append(
      UseRecord(
        action: "set", refs: [ref.path], command: nil,
        fullCommand: initiator.shellCommand.map(auditRedactor.redact),
        initiator: initiator, result: "approved"))
    Term.say("已存入 \(ref)（第 \(version) 版）", .ok)
    if version > 1 {
      Term.say("旧值还在第 \(version - 1) 版。", .dim)
    }
  }

  // MARK: run

  static func run(_ args: [String]) throws -> Int32 {
    guard let separator = args.firstIndex(of: "--") else {
      throw KagiError(
        .usage, "用法：kagi run --env 变量名=<引用> [--stdin <引用>] -- <命令> [参数...]",
        hint: "-- 后面是要运行的命令。")
    }
    var command = Array(args[(separator + 1)...])
    guard !command.isEmpty else {
      throw KagiError(.usage, "-- 后面要写要运行的命令。")
    }
    var parser = ArgParser(Array(args[..<separator]))
    var envRefs: [(name: String, ref: Ref)] = []
    while let pair = try parser.value(for: "--env") {
      guard let eq = pair.firstIndex(of: "="), isValidEnvName(String(pair[..<eq])) else {
        throw KagiError(.usage, "--env 的写法是 变量名=<引用>，比如 --env RESEND_API_KEY=resend/api-key。")
      }
      envRefs.append((String(pair[..<eq]), try Ref(String(pair[pair.index(after: eq)...]))))
    }
    var otpRefs: [(name: String, ref: Ref)] = []
    while let pair = try parser.value(for: "--otp") {
      guard let eq = pair.firstIndex(of: "="), isValidEnvName(String(pair[..<eq])) else {
        throw KagiError(.usage, "--otp 的写法是 变量名=<TOTP 引用>。")
      }
      otpRefs.append((String(pair[..<eq]), try Ref(String(pair[pair.index(after: eq)...]))))
    }
    let stdinRef = try parser.value(for: "--stdin").map { try Ref($0) }
    let otpStdinRef = try parser.value(for: "--otp-stdin").map { try Ref($0) }
    try parser.finish()
    guard stdinRef == nil || otpStdinRef == nil,
      Set((envRefs + otpRefs).map(\.name)).count == envRefs.count + otpRefs.count
    else {
      throw KagiError(.usage, "环境变量名不能重复，--stdin 与 --otp-stdin 不能同时使用。")
    }
    guard !envRefs.isEmpty || !otpRefs.isEmpty || stdinRef != nil || otpStdinRef != nil else {
      throw KagiError(.usage, "至少要用 --env 或 --stdin 交出一条值。")
    }

    command[0] = try Runner.resolveExecutable(command[0])
    let initiator = Initiator.current()
    let commandText = Term.commandLine(command)
    guard Term.displayWidth(commandText) <= Reason.commandWidth,
      !commandText.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw KagiError(
        .usage, "命令太长或包含控制字符，无法完整用于授权，命令没有运行。",
        hint: "请缩短命令；如使用脚本，请先由用户检查脚本内容。kagi 不验证脚本内容。")
    }
    var refs: [String] = []
    for ref in (envRefs + otpRefs).map(\.ref) + (stdinRef.map { [$0] } ?? [])
      + (otpStdinRef.map { [$0] } ?? []) where !refs.contains(ref.path)
    {
      refs.append(ref.path)
    }

    let session = try Session(local: localStore(), backend: backend())
    let listings = try session.listings()
    var resolved: [String: Listing] = [:]
    for ref in refs {
      guard let listing = listings.first(where: { $0.ref == ref }) else {
        useLog().append(
          UseRecord(
            action: "run", refs: refs, command: commandText, fullCommand: initiator.shellCommand,
            initiator: initiator, result: "notFound", exitCode: ExitCode.notFound.rawValue))
        throw notFound(ref, among: listings.map(\.ref))
      }
      resolved[ref] = listing
    }

    let otpPaths = Set(otpRefs.map { $0.ref.path } + (otpStdinRef.map { [$0.path] } ?? []))
    let rawPaths = Set(envRefs.map { $0.ref.path } + (stdinRef.map { [$0.path] } ?? []))
    guard rawPaths.allSatisfy({ resolved[$0]?.record.kind == .secret }),
      otpPaths.allSatisfy({ resolved[$0]?.record.kind == .totp })
    else {
      throw KagiError(.usage, "验证器种子/私钥不能通过普通 --env/--stdin 交出；TOTP 请用 --otp 或 --otp-stdin。")
    }
    let injections =
      envRefs.map { "\($0.name)=\($0.ref.path)" }
      + otpRefs.map { "TOTP \($0.name)=\($0.ref.path)" }
      + (stdinRef.map { ["stdin=\($0.path)"] } ?? [])
      + (otpStdinRef.map { ["TOTP stdin=\($0.path)"] } ?? [])
    let reason = try Reason.run(
      injections: injections, command: commandText,
      directory: FileManager.default.currentDirectoryPath, initiator: initiator)
    Term.say("等待指纹确认…", .dim)
    let key: SymmetricKey
    do {
      key = try session.unlock(reason: reason, action: .read, byAgent: initiator.isAgent)
    } catch let error as KagiError {
      useLog().append(
        UseRecord(
          action: "run", refs: refs, command: commandText, fullCommand: initiator.shellCommand,
          initiator: initiator,
          result: error.code == .denied ? "denied" : error.code == .tempFail ? "locked" : "error",
          exitCode: error.code.rawValue))
      throw error
    }

    var values: [(ref: String, value: Data)] = []
    let now = UInt64(Date().timeIntervalSince1970)
    for ref in refs {
      let value =
        try otpPaths.contains(ref)
        ? Data(session.totpCode(resolved[ref]!, at: now, key: key).code.utf8)
        : session.read(resolved[ref]!, key: key).value
      values.append((ref, value))
    }
    var environment: [String: String] = [:]
    for (name, ref) in envRefs + otpRefs {
      let value = values.first { $0.ref == ref.path }!.value
      guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else {
        throw KagiError(
          .usage, "\(ref) 的值不是文本，放不进环境变量。", hint: "改用 --stdin \(ref) 交给命令的标准输入。")
      }
      environment[name] = text
    }
    let stdinData = (stdinRef ?? otpStdinRef).map { ref in
      values.first { $0.ref == ref.path }!.value
    }

    let redactor = Redactor(values: values, minimumLength: 1)
    let code: Int32
    do {
      code = try Runner.run(
        argv: command, extraEnvironment: environment, stdinData: stdinData, values: values)
    } catch let error as KagiError {
      useLog().append(
        UseRecord(
          action: "run", refs: refs, command: redactor.redact(commandText),
          fullCommand: initiator.shellCommand.map(redactor.redact), initiator: initiator,
          result: "error",
          exitCode: error.code.rawValue))
      throw error
    }
    useLog().append(
      UseRecord(
        action: "run", refs: refs, command: redactor.redact(commandText),
        fullCommand: initiator.shellCommand.map(redactor.redact),
        initiator: initiator, result: "approved", exitCode: code))
    return code
  }

  static func isValidEnvName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first,
      first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
    else { return false }
    return name.unicodeScalars.allSatisfy {
      $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0))
    }
  }

  static func notFound(_ ref: String, among refs: [String]) -> KagiError {
    let suggestion = Ref.closest(to: ref, in: refs).map { "你是不是想用 \($0)？" } ?? ""
    return KagiError(.notFound, "没有 \(ref) 这一条。", hint: "\(suggestion)查看全部引用：kagi ls（不需要指纹）")
  }

  // MARK: ls、where

  static func list(_ args: [String]) throws {
    var parser = ArgParser(args)
    let json = parser.flag("--json")
    let all = parser.flag("--all")
    let archived = parser.flag("--archived")
    let space = try parser.value(for: "--space")
    let search = try parser.value(for: "--search")
    var tags: [String] = []
    while let tag = try parser.value(for: "--tag") { tags.append(tag) }
    try parser.finish()
    guard !(all && archived) else { throw KagiError(.usage, "--all 和 --archived 只能选一个。") }
    let session = try Session(local: localStore(), backend: backend())
    let listings = try session.queryKeys(
      KeyQuery(
        space: space, tags: tags, text: search,
        scope: all ? .all : archived ? .archived : .active))
    if json {
      try printJSON(listings)
      return
    }
    guard !listings.isEmpty else {
      Term.print("没有匹配的 key。存一条：kagi set <引用>")
      return
    }
    let rows = listings.map { item -> [String] in
      [
        item.ref, item.record.kind.rawValue, item.record.metadata.title ?? "—",
        item.record.metadata.space,
        item.record.metadata.tags.joined(separator: ", "),
        item.record.metadata.archived ? "已归档" : "可用",
      ]
    }
    printTable(header: ["引用", "类型", "名称", "Space", "标签", "状态"], rows: rows)
    Term.print("共 \(listings.count) 条 · 库 \(session.shortID) · 没有用指纹", .dim)
  }

  static func whereIs(_ args: [String]) throws {
    var parser = ArgParser(args)
    let json = parser.flag("--json")
    let positional = try parser.positionals()
    guard positional.count == 1 else { throw KagiError(.usage, "用法：kagi where <引用>") }
    let ref = try Ref(positional[0])
    let session = try Session(local: localStore(), backend: backend())
    let listings = try session.listings(includeArchived: true)
    guard let item = listings.first(where: { $0.ref == ref.path }) else {
      throw notFound(ref.path, among: listings.map(\.ref))
    }
    if json {
      try printJSON(item)
      return
    }
    let versions = try session.store.versions(of: item.entry)
    Term.print(item.ref, .bold)
    Term.print("  类型      \(item.record.kind.rawValue)")
    Term.print("  名称      \(item.record.metadata.title ?? "（未填）")")
    Term.print("  Space     \(item.record.metadata.space)")
    Term.print("  标签      \(item.record.metadata.tags.joined(separator: "、"))")
    Term.print("  状态      \(item.record.metadata.archived ? "已归档" : "可用")")
    if let notes = item.record.metadata.notes { Term.print("  备注      \(notes)") }
    Term.print("  签发方    \(item.record.issuer ?? "（未填）")")
    Term.print("  用在哪    \(item.record.usedIn ?? "（未填）")")
    Term.print("  创建      \(Term.shortTime(item.record.created))")
    Term.print(
      "  更新      \(Term.shortTime(item.record.updated))（第 \(versions.last ?? item.record.latestVersion) 版，共 \(versions.count) 版）"
    )
    if let last = useLog().read().last(where: {
      $0.refs.contains(ref.path) && $0.result == "approved" && $0.action == "run"
    }) {
      Term.print(
        "  最近使用  \(Term.shortTime(last.time)) · \(last.initiator) · \(Term.truncate(last.command ?? "", to: 48))"
      )
    }
    Term.print("值不会显示。要把它交给命令，用 kagi run。", .dim)
  }

  // MARK: log、guide

  static func log(_ args: [String]) throws {
    var parser = ArgParser(args)
    let full = parser.flag("--full")
    let count =
      try parser.value(for: "-n").map { text -> Int in
        guard let n = Int(text), n > 0 else { throw KagiError(.usage, "-n 后面要写正整数。") }
        return n
      } ?? 20
    try parser.finish()
    let records = Array(useLog().read().suffix(count))
    guard !records.isEmpty else {
      Term.print("还没有使用记录。")
      return
    }
    if full {
      for record in records {
        Term.print(
          "\(Term.longTime(record.time))  \(resultLabel(record.result))  \(record.refs.joined(separator: "、"))",
          .bold)
        Term.print("  动作      \(actionLabel(record.action))")
        if let command = record.command { Term.print("  命令      \(command)") }
        if let fullCommand = record.fullCommand { Term.print("  整条命令  \(fullCommand)") }
        Term.print("  发起      \(record.initiator)")
        Term.print("  进程链    \(record.chain.joined(separator: " ← "))")
        if let code = record.exitCode { Term.print("  退出码    \(code)") }
      }
      return
    }
    let rows = records.map { record -> [String] in
      [
        Term.shortTime(record.time), resultLabel(record.result),
        record.refs.isEmpty ? "—" : record.refs.joined(separator: "、"),
        Term.truncate(record.command ?? actionLabel(record.action), to: 44), record.initiator,
      ]
    }
    printTable(header: ["时间", "结果", "引用", "命令", "发起"], rows: rows)
    Term.print("完整命令和进程链：kagi log --full · 记录只在本机，不含任何值", .dim)
  }

  static func actionLabel(_ action: String) -> String {
    switch action {
    case "run": return "交给命令"
    case "set": return "存入"
    case "init": return "建库"
    case "recover": return "加入库"
    default: return action
    }
  }

  static func resultLabel(_ result: String) -> String {
    switch result {
    case "approved": return "批准"
    case "denied": return "拒绝"
    case "locked": return "锁屏"
    case "notFound": return "没找到"
    default: return "出错"
    }
  }

  static func printTable(header: [String], rows: [[String]]) {
    let widths = header.indices.map { column in
      ([header[column]] + rows.map { $0[column] }).map(Term.displayWidth).max() ?? 0
    }
    func line(_ cells: [String]) -> String {
      cells.enumerated().map { index, cell in
        index == cells.count - 1 ? cell : Term.pad(cell, to: widths[index])
      }.joined(separator: "  ")
    }
    Term.print(line(header), .bold)
    rows.forEach { Term.print(line($0)) }
  }

  static func repairIndex(_ args: [String]) throws {
    var parser = ArgParser(args)
    try parser.finish()
    let initiator = Initiator.current()
    let session = try Session(local: localStore(), backend: backend())
    let key = try session.unlock(
      reason: "解密库 \(session.shortID) 的全部条目并重建索引（\(Reason.by(initiator))）",
      action: .write, byAgent: initiator.isAgent)
    let count = try session.repairIndex(key: key)
    useLog().append(
      UseRecord(
        action: "repair-index", refs: [], command: nil, fullCommand: nil,
        initiator: initiator, result: "approved"))
    Term.say("已重建 \(count) 条索引。缺失索引的项会归档到默认 Space，管理信息需核对补填后再恢复。", .ok)
  }

  // MARK: recover

  static func recover(_ args: [String]) throws {
    var parser = ArgParser(args)
    let vaultOption = try parser.value(for: "--vault")
    let remoteOption = try parser.value(for: "--remote")
    let vaultID = try parser.value(for: "--vault-id")
    try parser.finish()
    guard (remoteOption == nil) == (vaultID == nil),
      vaultID == nil || (vaultID!.count <= 64 && vaultID!.utf8.allSatisfy {
        (97...122).contains($0) || (48...57).contains($0)
      } && !vaultID!.isEmpty), remoteOption == nil || remoteOption!.hasPrefix("/") else {
      throw KagiError(.usage, "远端恢复需要 --remote <绝对路径> 和 --vault-id <库 ID>。")
    }
    let initiator = Initiator.current()
    try requireTerminal("recover", "要输入恢复密钥", initiator: initiator)
    let local = localStore()
    if let state = try local.load() {
      throw KagiError(.config, "这台 Mac 已经在库 \(Kagi.shortID(state.vault)) 里了（\(state.vaultPath)）。")
    }
    let root = try vaultRoot(vaultOption)
    let store = VaultStore(root: root)
    if let remoteOption, let vaultID {
      Term.print("从同步仓库恢复库 \(vaultID)：\(remoteOption)，本地位置：\(root.path)")
    } else {
      let vault = try store.readVault()
      let count = try store.indexFiles().count
      Term.print("找到库 \(Kagi.shortID(vault.vault))（\(count) 条），位置：\(root.path)")
    }
    Term.print("这台 Mac 还不在库里。")

    var recoveryKey: RecoveryKey?
    for attempt in 1...3 {
      guard let typed = Term.readHidden("恢复密钥（输入时不显示）：") else { break }
      do {
        recoveryKey = try RecoveryKey(parsing: typed)
        break
      } catch let error as KagiError {
        Term.say("kagi：\(error.message)", .bad)
        if let hint = error.hint { Term.say(hint, .dim) }
        if attempt == 3 { throw error }
      }
    }
    guard let recoveryKey else { throw KagiError(.usage, "没有读到恢复密钥。") }

    Term.print("等待指纹确认…", .dim)
    let others = remoteOption == nil ? try store.devices() : []
    let joined: VaultFile
    let device: DeviceFile
    if let remoteOption, let vaultID {
      let transport = try DirectorySyncTransport(root: URL(fileURLWithPath: remoteOption).appendingPathComponent(vaultID))
      (joined, device) = try Kagi.recoverFromSync(with: transport, at: root,
        recoveryKey: recoveryKey, deviceName: computerName(), backend: backend(),
        local: local, reason: { "让这台 Mac 加入库 \($0)" })
    } else {
      (joined, device) = try Kagi.recover(
        at: root, recoveryKey: recoveryKey, deviceName: computerName(), backend: backend(),
        local: local, reason: { "让这台 Mac 加入库 \($0)" })
    }
    useLog().append(
      UseRecord(
        action: "recover", refs: [], command: nil, fullCommand: nil, initiator: initiator,
        result: "approved"))
    Term.print("恢复密钥正确。这台 Mac 已加入库 \(Kagi.shortID(joined.vault))（设备 \(device.device)）。", .ok)
    if !others.isEmpty {
      Term.print("库里还有这些设备：")
      for other in others {
        Term.print("  \(other.device)  \(other.name)  \(Term.shortTime(other.created)) 加入")
      }
      Term.print("如果其中有丢了的设备：之后要移除它并更换库密钥（第二版提供），再轮换里面重要的 key。", .dim)
    }
  }
}
