import Foundation

/// 引用：「签发方/名字」，比如 resend/api-key。只用小写字母、数字和 . _ -，用 / 分段。
public struct Ref: Hashable, Comparable, CustomStringConvertible, Sendable {
  public let path: String

  public init(_ raw: String) throws {
    let segments = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard !raw.isEmpty, raw.count <= 200, segments.allSatisfy(Ref.isValidSegment) else {
      throw KagiError(
        .usage, "引用「\(raw)」的写法不对。",
        hint: "引用由小写字母、数字和 . _ - 组成，用 / 分段，比如 resend/api-key。")
    }
    path = raw
  }

  public var description: String { path }

  public static func < (lhs: Ref, rhs: Ref) -> Bool { lhs.path < rhs.path }

  static func isValidSegment(_ segment: Substring) -> Bool {
    guard let first = segment.first, segment.count <= 64, isLowerOrDigit(first) else { return false }
    return segment.allSatisfy { isLowerOrDigit($0) || $0 == "." || $0 == "_" || $0 == "-" }
  }

  static func isLowerOrDigit(_ c: Character) -> Bool {
    c.isASCII && (c.isLowercase || c.isNumber)
  }

  /// 找最接近的引用，用来提示「你是不是想用……」。差得太远就不提示。
  public static func closest(to wanted: String, in candidates: [String]) -> String? {
    let limit = max(2, wanted.count / 5)
    return candidates
      .map { ($0, editDistance(wanted, $0)) }
      .filter { $0.1 <= limit }
      .min { $0.1 < $1.1 }?.0
  }

  static func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      previous = current
    }
    return previous[b.count]
  }
}
