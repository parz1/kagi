import Foundation

/// Crockford Base32：去掉了容易看混的 I、L、O、U。解码时 O 当 0，I 和 L 当 1，忽略大小写、横线和空格。
public enum Base32 {
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  public static func encode(_ data: Data) -> String {
    var output = ""
    var buffer = 0
    var bits = 0
    for byte in data {
      buffer = (buffer << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        output.append(alphabet[(buffer >> (bits - 5)) & 31])
        bits -= 5
      }
      buffer &= (1 << bits) - 1
    }
    if bits > 0 {
      output.append(alphabet[(buffer << (5 - bits)) & 31])
    }
    return output
  }

  /// 解码。遇到不认识的字符返回 nil。
  public static func decode(_ text: String) -> Data? {
    var buffer = 0
    var bits = 0
    var output = Data()
    for raw in text.uppercased() {
      if raw == "-" || raw == " " { continue }
      let c: Character
      switch raw {
      case "O": c = "0"
      case "I", "L": c = "1"
      default: c = raw
      }
      guard let value = alphabet.firstIndex(of: c) else { return nil }
      buffer = (buffer << 5) | value
      bits += 5
      if bits >= 8 {
        output.append(UInt8((buffer >> (bits - 8)) & 0xFF))
        bits -= 8
      }
      buffer &= (1 << bits) - 1
    }
    return output
  }
}
