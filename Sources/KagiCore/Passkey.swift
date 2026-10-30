import CryptoKit
import Foundation

public enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ value: String) throws -> Data {
    guard
      value.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0)
          || (48...57).contains($0) || $0 == 45 || $0 == 95
      }), value.count % 4 != 1
    else {
      throw KagiError(.usage, "无效的无填充 base64url。")
    }
    let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    guard
      let result = Data(
        base64Encoded: base64 + String(repeating: "=", count: (4 - value.count % 4) % 4)),
      encode(result) == value
    else { throw KagiError(.usage, "无效的无填充 base64url。") }
    return result
  }
}

/// 明确的核心联调协议，不直接接受浏览器 PublicKeyCredentialCreationOptions。
/// 来源必须由未来的可信浏览器/系统适配器验证；本模型仅检查来源与 RP ID 的绑定。
public struct PasskeyRequest: Codable, Equatable, Sendable {
  public let rpID: String
  public let origin: String
  public let challenge: String
  public let userHandle: String?
  public let userName: String?

  public init(
    rpID: String, origin: String, challenge: String, userHandle: String? = nil,
    userName: String? = nil
  ) {
    self.rpID = rpID
    self.origin = origin
    self.challenge = challenge
    self.userHandle = userHandle
    self.userName = userName
  }

  /// CLI 的严格 schema，拒绝尚未实现的 options，避免默默忽略 excludeCredentials 等要求。
  public static func parse(_ data: Data) throws -> PasskeyRequest {
    guard data.count <= 65536,
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      Set(object.keys).isSubset(of: ["rpID", "origin", "challenge", "userHandle", "userName"])
    else {
      throw KagiError(.usage, "Passkey 核心请求只接受 rpID、origin、challenge、userHandle、userName。")
    }
    guard let result = try? JSONDecoder().decode(PasskeyRequest.self, from: data) else {
      throw KagiError(.usage, "Passkey 核心请求 JSON 字段或类型无效。")
    }
    return result
  }

  public func validate(registration: Bool) throws {
    guard rpID.utf8.count <= 253, !rpID.isEmpty, rpID == rpID.lowercased(),
      rpID.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
        !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
      }), let url = URLComponents(string: origin), url.host == rpID, url.user == nil,
      url.password == nil,
      url.query == nil, url.fragment == nil, url.path.isEmpty,
      url.scheme == "https" || (url.scheme == "http" && rpID == "localhost"),
      url.port == nil || (1...65535).contains(url.port!),
      origin == "\(url.scheme!)://\(rpID)" + (url.port.map { ":\($0)" } ?? ""),
      !(url.scheme == "https" && url.port == 443), !(url.scheme == "http" && url.port == 80)
    else {
      throw KagiError(.usage, "Passkey 要求规范的 HTTPS origin 与 RP ID 完全匹配；仅 localhost 可用 HTTP。")
    }
    let challenge = try Base64URL.decode(challenge)
    guard (16...1024).contains(challenge.count) else {
      throw KagiError(.usage, "challenge 需为 16–1024 字节。")
    }
    if registration {
      guard let userHandle, (1...64).contains(try Base64URL.decode(userHandle).count),
        let userName, try ManagementText.optional(userName, limit: 200) == userName
      else {
        throw KagiError(.usage, "注册需要 1–64 字节 userHandle 和非空 userName。")
      }
    } else if userHandle != nil || userName != nil {
      throw KagiError(.usage, "认证请求不接受 userHandle 或 userName；由选中的凭据确定账号。")
    }
  }

  func clientData(operation: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "type": operation, "challenge": challenge,
        "origin": origin, "crossOrigin": false,
      ], options: [.sortedKeys, .withoutEscapingSlashes])
  }
}

public struct PasskeyRegistration: Codable, Sendable {
  public struct Response: Codable, Sendable {
    public let clientDataJSON: String
    public let attestationObject: String
  }
  public let id: String
  public let rawId: String
  public let type: String
  public let response: Response
}

public struct PasskeyAssertion: Codable, Sendable {
  public struct Response: Codable, Sendable {
    public let clientDataJSON: String
    public let authenticatorData: String
    public let signature: String
    public let userHandle: String
  }
  public let id: String
  public let rawId: String
  public let type: String
  public let response: Response
}

/// 私钥只序列化进 Vault 的加密值区。此版本是可备份的软件凭据；计数器恒为零。
/// 核心联调模拟 UP/UV 成功；不是已集成系统的 Passkey 提供者。
public struct PasskeyCredential: Codable, Sendable {
  public let rpID: String
  public let credentialID: Data
  public let userHandle: Data
  public let userName: String
  let privateKey: Data

  public static func create(for request: PasskeyRequest) throws -> PasskeyCredential {
    try request.validate(registration: true)
    return PasskeyCredential(
      rpID: request.rpID, credentialID: Crypto.randomBytes(32),
      userHandle: try Base64URL.decode(request.userHandle!), userName: request.userName!,
      privateKey: P256.Signing.PrivateKey().rawRepresentation)
  }

  func validate() throws {
    guard (16...1024).contains(credentialID.count), (1...64).contains(userHandle.count),
      !userName.isEmpty, privateKey.count == 32
    else { throw KeyFailure.tampered }
    _ = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
    try PasskeyRequest(
      rpID: rpID, origin: "https://\(rpID)",
      challenge: Base64URL.encode(Data(repeating: 0, count: 32)),
      userHandle: Base64URL.encode(userHandle), userName: userName
    ).validate(registration: true)
  }

  private func authenticatorData(registration: Bool) throws -> Data {
    // UP + UV + BE；BS=0（本机核心尚未确认外部备份），AT 仅注册时置位。
    var data = Data(SHA256.hash(data: Data(rpID.utf8)))
    data.append(registration ? 0x4D : 0x0D)
    data.append(Data(repeating: 0, count: 4))  // 不维护签名计数器，WebAuthn 允许恒零。
    if registration {
      data.append(Data(repeating: 0, count: 16))  // none attestation，零 AAGUID。
      var length = UInt16(credentialID.count).bigEndian
      data.append(withUnsafeBytes(of: &length) { Data($0) })
      data.append(credentialID)
      let publicKey = try P256.Signing.PrivateKey(rawRepresentation: privateKey).publicKey
        .x963Representation
      data.append(
        CBOR.map([
          (.integer(1), .integer(2)), (.integer(3), .integer(-7)), (.integer(-1), .integer(1)),
          (.integer(-2), .bytes(publicKey.subdata(in: 1..<33))),
          (.integer(-3), .bytes(publicKey.subdata(in: 33..<65))),
        ]).encoded)
    }
    return data
  }

  public func registration(for request: PasskeyRequest) throws -> PasskeyRegistration {
    try validate()
    try request.validate(registration: true)
    guard request.rpID == rpID, try Base64URL.decode(request.userHandle!) == userHandle,
      request.userName == userName
    else { throw KagiError(.usage, "注册请求与凭据不匹配。") }
    let attestation = CBOR.map([
      (.text("fmt"), .text("none")),
      (.text("authData"), .bytes(try authenticatorData(registration: true))),
      (.text("attStmt"), .map([])),
    ]).encoded
    let id = Base64URL.encode(credentialID)
    return PasskeyRegistration(
      id: id, rawId: id, type: "public-key",
      response: .init(
        clientDataJSON: Base64URL.encode(try request.clientData(operation: "webauthn.create")),
        attestationObject: Base64URL.encode(attestation)))
  }

  public func assertion(for request: PasskeyRequest) throws -> PasskeyAssertion {
    try validate()
    try request.validate(registration: false)
    guard request.rpID == rpID else { throw KagiError(.denied, "凭据不属于请求的 RP。") }
    let clientData = try request.clientData(operation: "webauthn.get")
    let authData = try authenticatorData(registration: false)
    let signature = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
      .signature(for: authData + Data(SHA256.hash(data: clientData))).derRepresentation
    let id = Base64URL.encode(credentialID)
    return PasskeyAssertion(
      id: id, rawId: id, type: "public-key",
      response: .init(
        clientDataJSON: Base64URL.encode(clientData), authenticatorData: Base64URL.encode(authData),
        signature: Base64URL.encode(signature), userHandle: Base64URL.encode(userHandle)))
  }
}

/// 只编码核心所需的 CBOR 数据类型；不处理外部 CBOR 输入。
indirect enum CBOR {
  case integer(Int)
  case bytes(Data)
  case text(String)
  case map([(CBOR, CBOR)])

  private func header(_ major: UInt8, _ size: UInt64) -> Data {
    if size < 24 { return Data([major << 5 | UInt8(size)]) }
    if size <= 255 { return Data([major << 5 | 24, UInt8(size)]) }
    if size <= 65535 {
      return Data([major << 5 | 25, UInt8(size >> 8), UInt8(size & 255)])
    }
    precondition(size <= UInt32.max)
    return Data([
      major << 5 | 26, UInt8(size >> 24), UInt8((size >> 16) & 255),
      UInt8((size >> 8) & 255), UInt8(size & 255),
    ])
  }

  var encoded: Data {
    switch self {
    case .integer(let value):
      return header(value >= 0 ? 0 : 1, UInt64(value >= 0 ? value : -1 - value))
    case .bytes(let value): return header(2, UInt64(value.count)) + value
    case .text(let value):
      let data = Data(value.utf8)
      return header(3, UInt64(data.count)) + data
    case .map(let values):
      return header(5, UInt64(values.count))
        + values.reduce(into: Data()) { $0 += $1.0.encoded + $1.1.encoded }
    }
  }
}
