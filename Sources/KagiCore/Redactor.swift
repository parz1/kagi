import Foundation

/// 把输出流里出现的值换成 ‹kagi:引用›。值被切在两段输出之间也能换掉。
/// 打码只防无意泄露：程序先编码再打印，就绕过去了。
public final class Redactor: @unchecked Sendable {
  struct Secret {
    let bytes: [UInt8]
    let replacement: [UInt8]
  }

  /// 太短的值不打码，否则正常输出会被误伤。
  public static let minimumLength = 6

  let secrets: [Secret]
  var pending: [UInt8] = []
  let lock = NSLock()

  public init(values: [(ref: String, value: Data)], minimumLength: Int = Redactor.minimumLength) {
    secrets =
      values
      .filter { !$0.value.isEmpty && $0.value.count >= minimumLength }
      .map { Secret(bytes: Array($0.value), replacement: Array("‹kagi:\($0.ref)›".utf8)) }
      .sorted { $0.bytes.count > $1.bytes.count }
  }

  /// 喂进一段输出，返回可以马上写出去的部分。末尾可能是某个值开头的那几个字节，先留着。
  public func feed(_ data: Data) -> Data {
    lock.lock()
    defer { lock.unlock() }
    pending += data
    return Data(drain(final: false))
  }

  /// 输出结束，把留着的部分也写出去。
  public func finish() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return Data(drain(final: true))
  }

  func drain(final: Bool) -> [UInt8] {
    guard !secrets.isEmpty else {
      defer { pending = [] }
      return pending
    }
    var output: [UInt8] = []
    var i = 0
    let count = pending.count
    scan: while i < count {
      // 短验证码也可能是另一个较长值的前缀；分块未完整时先等待，不能先消费短匹配。
      if !final, isPrefixOfSecret(from: i) {
        break
      }
      for secret in secrets where matches(secret.bytes, at: i) {
        output += secret.replacement
        i += secret.bytes.count
        continue scan
      }
      output.append(pending[i])
      i += 1
    }
    pending = Array(pending[i...])
    return output
  }

  func matches(_ bytes: [UInt8], at index: Int) -> Bool {
    guard index + bytes.count <= pending.count else { return false }
    for j in 0..<bytes.count where pending[index + j] != bytes[j] { return false }
    return true
  }

  /// pending[index...] 还不够长，但可能是某个值的开头。
  func isPrefixOfSecret(from index: Int) -> Bool {
    let rest = pending.count - index
    return secrets.contains { secret in
      rest < secret.bytes.count && (0..<rest).allSatisfy { pending[index + $0] == secret.bytes[$0] }
    }
  }

  /// 给字符串打码，用在使用记录里。
  public func redact(_ text: String) -> String {
    var result = text
    for secret in secrets {
      if let value = String(bytes: secret.bytes, encoding: .utf8), !value.isEmpty {
        result = result.replacingOccurrences(
          of: value, with: String(decoding: secret.replacement, as: UTF8.self))
      }
    }
    return result
  }
}
