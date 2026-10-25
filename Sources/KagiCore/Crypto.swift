import CryptoKit
import Foundation
import Security

/// kagi 用到的全部加密运算。只调 CryptoKit 和系统随机数，不自己实现任何算法。
public enum Crypto {
  public static let hpkeSuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

  public static func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "系统随机数不可用")
    return Data(bytes)
  }

  public static func newKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  public static func keyData(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
  }

  /// 库内密钥的校验值：HMAC-SHA256(密钥, 绑定串)。用来发现包装被调包。
  public static func keyCheck(_ key: SymmetricKey, vault: String, purpose: KeyPurpose) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: Binding.keyCheck(vault: vault, purpose: purpose), using: key)
    return Data(mac).base64EncodedString()
  }

  /// AES-256-GCM 加密，返回 nonce‖密文‖tag 的 Base64。
  public static func seal(_ plaintext: Data, key: SymmetricKey, binding: Data) throws -> String {
    let box = try AES.GCM.seal(plaintext, using: key, authenticating: binding)
    guard let combined = box.combined else {
      throw KagiError(.software, "加密结果不完整。")
    }
    return combined.base64EncodedString()
  }

  /// AES-256-GCM 解密。密文被改过、绑定不对或钥匙不对时抛 KeyFailure.tampered。
  public static func open(_ text: String, key: SymmetricKey, binding: Data) throws -> Data {
    guard let combined = Data(base64Encoded: text) else { throw KeyFailure.tampered }
    do {
      let box = try AES.GCM.SealedBox(combined: combined)
      return try AES.GCM.open(box, using: key, authenticating: binding)
    } catch {
      throw KeyFailure.tampered
    }
  }

  /// 用对方的公钥做 HPKE 封装（base 模式）。
  public static func hpkeSeal(
    _ plaintext: Data, to publicKey: P256.KeyAgreement.PublicKey, binding: Data
  ) throws -> HPKEBox {
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: hpkeSuite, info: binding)
    let ciphertext = try sender.seal(plaintext, authenticating: binding)
    return HPKEBox(
      enc: sender.encapsulatedKey.base64EncodedString(),
      ciphertext: ciphertext.base64EncodedString())
  }

  /// 用私钥解开 HPKE 封装。私钥可以是 Secure Enclave 里的，也可以是软件密钥（只在测试里用）。
  public static func hpkeOpen<Key: HPKEDiffieHellmanPrivateKey>(
    _ box: HPKEBox, with key: Key, binding: Data
  ) throws -> Data {
    guard let enc = Data(base64Encoded: box.enc), let ciphertext = Data(base64Encoded: box.ciphertext)
    else { throw KeyFailure.tampered }
    var recipient = try HPKE.Recipient(
      privateKey: key, ciphersuite: hpkeSuite, info: binding, encapsulatedKey: enc)
    return try recipient.open(ciphertext, authenticating: binding)
  }

  public static func publicKeyText(_ key: P256.KeyAgreement.PublicKey) -> String {
    key.x963Representation.base64EncodedString()
  }

  public static func publicKey(from text: String) throws -> P256.KeyAgreement.PublicKey {
    guard let data = Data(base64Encoded: text),
      let key = try? P256.KeyAgreement.PublicKey(x963Representation: data)
    else { throw KagiError(.dataError, "设备公钥读不懂，可能被改过。") }
    return key
  }
}
