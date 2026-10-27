import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 一把设备密钥：私钥只以 blob 的形式离开密钥后端（Secure Enclave 的 blob 拷到别的机器上没用）。
public struct DeviceKeyPair: Sendable {
  public let blob: Data
  public let publicKey: P256.KeyAgreement.PublicKey
}

/// 设备密钥放在哪里。正式运行用 Secure Enclave；测试用软件密钥。
public protocol KeyBackend: Sendable {
  var isAvailable: Bool { get }
  /// 新建一把设备密钥。requiresUserPresence 为 true 时，每次使用都要按指纹或输登录密码。
  func makeKey(requiresUserPresence: Bool) throws -> DeviceKeyPair
  /// 用要求指纹的设备密钥解开 HPKE 封装。会弹出指纹框，reason 显示在框里。
  func openWithPresence(_ box: HPKEBox, blob: Data, binding: Data, reason: String) throws -> Data
  /// 用不要求指纹的设备密钥解开 HPKE 封装。不弹框。
  func openSilently(_ box: HPKEBox, blob: Data, binding: Data) throws -> Data
}

public struct SecureEnclaveBackend: KeyBackend {
  public init() {}

  public var isAvailable: Bool { SecureEnclave.isAvailable }

  public func makeKey(requiresUserPresence: Bool) throws -> DeviceKeyPair {
    var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
    if requiresUserPresence { flags.insert(.userPresence) }
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error)
    else {
      throw Self.failure(from: error?.takeRetainedValue() ?? NSError(domain: "kagi", code: -1))
    }
    do {
      let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
      return DeviceKeyPair(blob: key.dataRepresentation, publicKey: key.publicKey)
    } catch {
      throw Self.failure(from: error)
    }
  }

  public func openWithPresence(_ box: HPKEBox, blob: Data, binding: Data, reason: String) throws -> Data {
    let context = LAContext()
    context.localizedReason = reason
    defer { context.invalidate() }
    do {
      let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: blob, authenticationContext: context)
      return try Crypto.hpkeOpen(box, with: key, binding: binding)
    } catch {
      throw Self.failure(from: error)
    }
  }

  public func openSilently(_ box: HPKEBox, blob: Data, binding: Data) throws -> Data {
    // 这把密钥本来就不要求验证；万一要求了，宁可失败也不弹框。
    let context = LAContext()
    context.interactionNotAllowed = true
    defer { context.invalidate() }
    do {
      let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: blob, authenticationContext: context)
      return try Crypto.hpkeOpen(box, with: key, binding: binding)
    } catch {
      throw Self.failure(from: error)
    }
  }

  /// 把系统给的各种错误归成几类。实测：点取消是 LocalAuthentication -2；锁屏时是 -25308。
  static func failure(from error: Error) -> KeyFailure {
    if let failure = error as? KeyFailure { return failure }
    if let crypto = error as? CryptoKitError, case .authenticationFailure = crypto { return .tampered }
    let ns = error as NSError
    switch (ns.domain, ns.code) {
    case (LAError.errorDomain, LAError.userCancel.rawValue),
      (LAError.errorDomain, LAError.systemCancel.rawValue),
      (LAError.errorDomain, LAError.appCancel.rawValue),
      (LAError.errorDomain, LAError.authenticationFailed.rawValue),
      (LAError.errorDomain, LAError.userFallback.rawValue):
      return .denied
    case (LAError.errorDomain, LAError.notInteractive.rawValue):
      return .locked
    case (_, Int(errSecUserCanceled)), (_, Int(errSecAuthFailed)):
      return .denied
    case (_, Int(errSecInteractionNotAllowed)):
      return .locked
    default:
      return .other("\(ns.domain) \(ns.code) \(ns.localizedDescription)")
    }
  }
}

/// 软件密钥：只给测试和调试版用，发布版不会走到这里。
public final class SoftwareBackend: KeyBackend, @unchecked Sendable {
  /// 模拟用户在指纹框里的选择。
  public enum Decision: Sendable {
    case approve
    case deny
    case locked
  }

  public var decision: Decision
  public private(set) var prompts: [String] = []
  private let onPrompt: (@Sendable (String) -> Void)?

  public init(decision: Decision = .approve, onPrompt: (@Sendable (String) -> Void)? = nil) {
    self.decision = decision
    self.onPrompt = onPrompt
  }

  public var isAvailable: Bool { true }

  public func makeKey(requiresUserPresence: Bool) throws -> DeviceKeyPair {
    let key = P256.KeyAgreement.PrivateKey()
    return DeviceKeyPair(blob: key.rawRepresentation, publicKey: key.publicKey)
  }

  public func openWithPresence(_ box: HPKEBox, blob: Data, binding: Data, reason: String) throws -> Data {
    prompts.append(reason)
    onPrompt?(reason)
    switch decision {
    case .approve: break
    case .deny: throw KeyFailure.denied
    case .locked: throw KeyFailure.locked
    }
    return try open(box, blob: blob, binding: binding)
  }

  public func openSilently(_ box: HPKEBox, blob: Data, binding: Data) throws -> Data {
    if case .locked = decision { throw KeyFailure.locked }
    return try open(box, blob: blob, binding: binding)
  }

  func open(_ box: HPKEBox, blob: Data, binding: Data) throws -> Data {
    do {
      let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: blob)
      return try Crypto.hpkeOpen(box, with: key, binding: binding)
    } catch let failure as KeyFailure {
      throw failure
    } catch {
      throw KeyFailure.tampered
    }
  }
}
