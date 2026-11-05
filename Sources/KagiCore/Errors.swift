import Foundation

/// kagi 自己的退出码。run 成功时原样返回子进程的退出码。
public enum ExitCode: Int32, Sendable {
  /// 用法不对。
  case usage = 64
  /// 文件被改过、坏了，或者恢复密钥不对。
  case dataError = 65
  /// 引用不存在。
  case notFound = 66
  /// kagi 自己出错。
  case software = 70
  /// 屏幕锁着，暂时弹不了指纹框。
  case tempFail = 75
  /// 用户拒绝了。
  case denied = 77
  /// 还没初始化，或者这台 Mac 不在库里。
  case config = 78
  /// 找不到要运行的命令（和 shell 的约定一致）。
  case commandNotFound = 127
}

/// 打印给人或 agent 看的错误：第一句说发生了什么，第二句说下一步怎么做。
public struct KagiError: Error, CustomStringConvertible {
  public let code: ExitCode
  public let message: String
  public let hint: String?
  private let audit: String?

  public init(_ code: ExitCode, _ message: String, hint: String? = nil, audit: String? = nil) {
    self.code = code
    self.message = message
    self.hint = hint
    self.audit = audit
  }

  /// 写进使用记录的结果。同样是 75 时靠它区分锁屏、超时和被沙箱拦住。
  public var auditResult: String {
    audit ?? (code == .denied ? "denied" : code == .tempFail ? "locked" : "error")
  }

  public var description: String {
    hint.map { "\(message)\n\($0)" } ?? message
  }
}

/// 设备密钥出错的几种情况。命令层按场景翻译成具体的话。
public enum KeyFailure: Error, Equatable {
  /// 用户点了取消，或者验证没通过。
  case denied
  /// 屏幕锁着，或者现在不能弹框。
  case locked
  /// 密文被改过，或者不属于这把钥匙。
  case tampered
  /// 等了这么多秒系统验证仍未完成，已取消（验证框可能根本没有显示）。
  case timedOut(Int)
  /// 进程在沙箱里，连不上系统验证或 Secure Enclave（例如 seatbelt 拒绝了相关服务）。带系统的原始描述。
  case blocked(String)
  /// 其他错误，带原始描述。
  case other(String)
}
