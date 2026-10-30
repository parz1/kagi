import CryptoKit
import Foundation

/// RFC 4648 Base32；与库 ID/恢复密钥的 Crockford Base32 是不同编码。
public enum OTPBase32 {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

  public static func decode(_ input: String) throws -> Data {
    guard input.utf8.count <= 1640,
      input.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (50...55).contains($0) || $0 == 61
      })
    else { throw KagiError(.usage, "TOTP secret 包含非法 Base32 字符或长度超限。") }
    let text = input.uppercased()
    let body = String(text.prefix { $0 != "=" })
    let padding = text.count - body.count
    let remainders = [0: 0, 2: 6, 4: 4, 5: 3, 7: 1]
    guard !body.isEmpty, let expected = remainders[body.count % 8],
      padding == 0 || (padding == expected && text.count % 8 == 0),
      text.dropFirst(body.count).allSatisfy({ $0 == "=" })
    else {
      throw KagiError(.usage, "TOTP secret 不是有效的 RFC 4648 Base32。")
    }
    var buffer = 0
    var bits = 0
    var result = Data()
    for character in body {
      guard let value = alphabet.firstIndex(of: character) else {
        throw KagiError(.usage, "TOTP secret 包含非法 Base32 字符。")
      }
      buffer = (buffer << 5) | value
      bits += 5
      if bits >= 8 {
        result.append(UInt8((buffer >> (bits - 8)) & 255))
        bits -= 8
      }
      buffer &= (1 << bits) - 1
    }
    guard buffer == 0 else { throw KagiError(.usage, "TOTP secret 的尾部填充位非零。") }
    return result
  }
}

public enum OTPAlgorithm: String, Codable, Sendable {
  case sha1 = "SHA1"
  case sha256 = "SHA256"
  case sha512 = "SHA512"
}

public struct TOTPCode: Codable, Equatable, Sendable {
  public let code: String
  public let validFrom: UInt64
  public let validUntil: UInt64
}

public struct TOTPCredential: Codable, Equatable, Sendable {
  public let secret: Data
  public let algorithm: OTPAlgorithm
  public let digits: Int
  public let period: UInt64
  public let issuer: String?
  public let account: String?

  public init(
    secret: Data, algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: UInt64 = 30,
    issuer: String? = nil, account: String? = nil
  ) throws {
    guard !secret.isEmpty, secret.count <= 1024, (6...8).contains(digits),
      (1...86400).contains(period)
    else {
      throw KagiError(.usage, "TOTP 参数无效：secret 不能为空，位数需为 6–8，周期需为 1–86400 秒。")
    }
    self.secret = secret
    self.algorithm = algorithm
    self.digits = digits
    self.period = period
    self.issuer = try ManagementText.optional(issuer, limit: 200)
    self.account = try ManagementText.optional(account, limit: 200)
  }

  /// 接受 otpauth://totp URI 或纯 RFC 4648 Base32。拒绝 HOTP、重复和未知参数。
  public static func parse(_ input: String) throws -> TOTPCredential {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.lowercased().hasPrefix("otpauth:") else {
      return try TOTPCredential(secret: OTPBase32.decode(text))
    }
    guard let url = URLComponents(string: text), url.scheme?.lowercased() == "otpauth",
      url.host == "totp",
      url.user == nil, url.password == nil, url.port == nil, url.fragment == nil
    else {
      throw KagiError(.usage, "只支持 otpauth://totp URI。")
    }
    var parameters: [String: String] = [:]
    for item in url.queryItems ?? [] {
      guard ["secret", "issuer", "algorithm", "digits", "period"].contains(item.name),
        parameters[item.name] == nil, let value = item.value, !value.isEmpty
      else {
        throw KagiError(.usage, "TOTP URI 含重复、空值或不支持的参数。")
      }
      parameters[item.name] = value
    }
    guard let secret = parameters["secret"], url.path.hasPrefix("/"), url.path.count > 1 else {
      throw KagiError(.usage, "TOTP URI 缺少 secret 或账号标签。")
    }
    let label = String(url.path.dropFirst())
    let pieces = label.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let labelIssuer = pieces.count == 2 ? String(pieces[0]) : nil
    if let issuer = parameters["issuer"], let labelIssuer, issuer != labelIssuer {
      throw KagiError(.usage, "TOTP URI 的 issuer 与标签前缀不一致。")
    }
    guard let algorithm = OTPAlgorithm(rawValue: parameters["algorithm"]?.uppercased() ?? "SHA1"),
      let digits = Int(parameters["digits"] ?? "6"),
      let period = UInt64(parameters["period"] ?? "30")
    else {
      throw KagiError(.usage, "TOTP URI 算法、位数或周期无效。")
    }
    return try TOTPCredential(
      secret: OTPBase32.decode(secret), algorithm: algorithm, digits: digits,
      period: period, issuer: parameters["issuer"] ?? labelIssuer, account: String(pieces.last!))
  }

  public func code(at unixTime: UInt64) throws -> TOTPCode {
    // Codable 输入也必须经过相同参数验证。
    _ = try TOTPCredential(
      secret: secret, algorithm: algorithm, digits: digits, period: period,
      issuer: issuer, account: account)
    let counter = unixTime / period
    var bigEndian = counter.bigEndian
    let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
    let key = SymmetricKey(data: secret)
    let digest: [UInt8]
    switch algorithm {
    case .sha1: digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
    case .sha256: digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
    case .sha512: digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
    }
    let offset = Int(digest.last! & 15)
    let number =
      (UInt32(digest[offset] & 127) << 24) | (UInt32(digest[offset + 1]) << 16)
      | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
    let modulus: UInt32 = digits == 6 ? 1_000_000 : digits == 7 ? 10_000_000 : 100_000_000
    let start = unixTime - unixTime % period
    let (end, overflow) = start.addingReportingOverflow(period)
    guard !overflow else { throw KagiError(.usage, "TOTP 时间超出范围。") }
    return TOTPCode(
      code: String(format: "%0*u", digits, number % modulus), validFrom: start, validUntil: end)
  }
}
