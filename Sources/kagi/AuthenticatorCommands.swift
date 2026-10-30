import CryptoKit
import Foundation
import KagiCore

extension Commands {
  static func totp(_ args: [String]) throws {
    guard let action = args.first, ["import", "code"].contains(action) else {
      throw KagiError(
        .usage, "用法：kagi totp import <引用> --stdin [--space <ID>] [--tag <标签>]；code <引用> [--json]")
    }
    var parser = ArgParser(Array(args.dropFirst()))
    let json = parser.flag("--json")
    let stdin = parser.flag("--stdin")
    let space = try parser.value(for: "--space")
    let title = try parser.value(for: "--title")
    var tags: [String] = []
    while let tag = try parser.value(for: "--tag") { tags.append(tag) }
    let positional = try parser.positionals()
    guard positional.count == 1 else { throw KagiError(.usage, "请指定一条 TOTP 引用。") }
    let ref = try Ref(positional[0])
    let session = try Session(local: localStore(), backend: backend())
    if action == "import" {
      guard stdin, !json else { throw KagiError(.usage, "TOTP 导入只接受 --stdin，不能把种子写进参数。") }
      let data = FileHandle.standardInput.readDataToEndOfFile()
      guard data.count <= 65536, let input = String(data: data, encoding: .utf8) else {
        throw KagiError(.usage, "TOTP 导入需为最多 64 KiB 的 UTF-8 URI 或 Base32。")
      }
      let credential = try TOTPCredential.parse(input)
      let metadata = KeyMetadata(title: title, space: space ?? "default", tags: tags)
      try managementWrite(
        session: session, action: "totp-import", refs: [ref.path],
        reason: "存入 TOTP「\(ref.path)」，种子不显示"
      ) { key in
        try session.importTOTP(ref: ref, credential: credential, metadata: metadata, key: key)
      }
      Term.say("已存入 TOTP \(ref.path)。", .ok)
    } else {
      guard !stdin, space == nil, title == nil, tags.isEmpty else {
        throw KagiError(.usage, "code 只接受引用与 --json。")
      }
      guard let item = try session.find(ref) else { throw notFound(ref.path, among: []) }
      guard item.record.kind == .totp else { throw KagiError(.usage, "该引用不是 TOTP。") }
      var result: TOTPCode?
      try managementWrite(
        session: session, action: "totp-code", refs: [ref.path],
        reason: "生成 TOTP「\(ref.path)」的当前验证码，种子不交出", access: .read
      ) { key in
        result = try session.totpCode(item, at: UInt64(Date().timeIntervalSince1970), key: key)
      }
      if json { try printJSON(result!) } else { Term.print(result!.code) }
    }
  }

  /// 核心联调命令只存在于 fake 调试流程；可信系统/浏览器适配器尚未实现。
  static func passkey(_ args: [String]) throws {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["KAGI_DEBUG_SOFTWARE_KEYS"] == "1" else {
        throw KagiError(.usage, "Passkey CLI 目前只开放 fake 核心联调，需调试版软件密钥。")
      }
    #else
      throw KagiError(.usage, "Passkey 核心尚未接入系统提供者，发布版不开放此联调命令。")
    #endif
    #if DEBUG
      guard let action = args.first, ["register", "assert"].contains(action) else {
        throw KagiError(.usage, "用法：kagi passkey register|assert <引用> --stdin；请求是核心协议 JSON。")
      }
      var parser = ArgParser(Array(args.dropFirst()))
      let stdin = parser.flag("--stdin")
      let space = try parser.value(for: "--space")
      let title = try parser.value(for: "--title")
      var tags: [String] = []
      while let tag = try parser.value(for: "--tag") { tags.append(tag) }
      let positional = try parser.positionals()
      guard stdin, positional.count == 1 else {
        throw KagiError(.usage, "请通过 --stdin 传入请求，并指定凭据引用。")
      }
      if action == "assert", space != nil || title != nil || !tags.isEmpty {
        throw KagiError(.usage, "assert 不接受管理写入选项。")
      }
      let ref = try Ref(positional[0])
      let request = try PasskeyRequest.parse(FileHandle.standardInput.readDataToEndOfFile())
      try request.validate(registration: action == "register")
      let session = try Session(local: localStore(), backend: backend())
      Term.say("（Passkey fake 核心联调：来源由测试请求提供，尚未接入可信浏览器/系统来源验证）", .warn)
      if action == "register" {
        var result: PasskeyRegistration?
        try managementWrite(
          session: session, action: "passkey-register", refs: [ref.path],
          reason: "为 RP「\(request.rpID)」注册 Passkey「\(ref.path)」"
        ) { key in
          result = try session.registerPasskey(
            ref: ref, request: request,
            metadata: KeyMetadata(title: title, space: space ?? "default", tags: tags), key: key)
        }
        try printJSON(result!)
      } else {
        guard let item = try session.find(ref) else { throw notFound(ref.path, among: []) }
        guard item.record.kind == .passkey else { throw KagiError(.usage, "该引用不是 Passkey。") }
        var result: PasskeyAssertion?
        try managementWrite(
          session: session, action: "passkey-assert", refs: [ref.path],
          reason: "使用 Passkey「\(ref.path)」认证 RP「\(request.rpID)」", access: .read
        ) { key in
          result = try session.assertPasskey(item, request: request, key: key)
        }
        try printJSON(result!)
      }
    #endif
  }
}
