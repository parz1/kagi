import CryptoKit
import Foundation

/// 恢复密钥：18 字节随机数，加 2 字节校验，写成 8 组、每组 4 个 Crockford Base32 字符。
public struct RecoveryKey: Equatable, Sendable {
  public static let secretLength = 18
  static let checksumLength = 2

  public let secret: Data

  public init(secret: Data) {
    precondition(secret.count == Self.secretLength)
    self.secret = secret
  }

  public static func generate() -> RecoveryKey {
    RecoveryKey(secret: Crypto.randomBytes(secretLength))
  }

  /// 给人抄写的样子：XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX。
  public var displayText: String {
    let text = Base32.encode(secret + Self.checksum(of: secret))
    return stride(from: 0, to: text.count, by: 4).map { start -> String in
      let from = text.index(text.startIndex, offsetBy: start)
      let to = text.index(from, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
      return String(text[from..<to])
    }.joined(separator: "-")
  }

  public var lastGroup: String {
    String(displayText.suffix(4))
  }

  /// 解析人输入的恢复密钥。大小写、横线、空格都不用管，O 当 0，I 和 L 当 1。
  public init(parsing input: String) throws {
    guard let bytes = Base32.decode(input) else {
      throw KagiError(
        .dataError, "恢复密钥里有不认识的字符。", hint: "恢复密钥只有数字和大写字母，没有 U。请再核对一遍。")
    }
    guard bytes.count == Self.secretLength + Self.checksumLength else {
      throw KagiError(.dataError, "恢复密钥的长度不对。", hint: "应该是 8 组、每组 4 个字符。")
    }
    let secret = bytes.prefix(Self.secretLength)
    guard bytes.suffix(Self.checksumLength) == Self.checksum(of: secret) else {
      throw KagiError(
        .dataError, "恢复密钥不对：校验没通过，可能有一位抄错了。",
        hint: "大小写、横线、O 和 0 都不用管。其余字符请再核对一遍，或者用「密码」App 里存的那份。")
    }
    self.secret = Data(secret)
  }

  /// 从恢复密钥派生的加密密钥：HKDF-SHA256，盐里带库 ID。
  public func keyEncryptionKey(vault: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: secret),
      salt: Data("\(Format.recovery)|\(vault)".utf8),
      info: Data("kagi recovery key-encryption key".utf8),
      outputByteCount: 32)
  }

  static func checksum(of secret: Data) -> Data {
    var hasher = SHA256()
    hasher.update(data: Data("kagi-recovery-checksum/1".utf8))
    hasher.update(data: secret)
    return Data(hasher.finalize().prefix(checksumLength))
  }
}
