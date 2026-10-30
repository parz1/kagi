import CryptoKit
import Foundation

public enum CredentialKind: String, Codable, Sendable {
  case secret, totp, passkey
}

extension Session {
  public func importTOTP(
    ref: Ref, credential: TOTPCredential, metadata: KeyMetadata = KeyMetadata(),
    key: SymmetricKey
  ) throws {
    _ = try credential.code(at: 0)
    let existing = try find(ref, includeArchived: true)
    guard existing == nil || existing?.record.kind == .totp else {
      throw KagiError(.usage, "该引用已属于其他类型的凭据。")
    }
    try write(
      ref: ref, value: JSON.encode(credential), issuer: credential.issuer, usedIn: nil,
      existing: existing, key: key, metadata: existing?.record.metadata ?? metadata, kind: .totp)
  }

  public func totpCode(_ item: Listing, at unixTime: UInt64, key: SymmetricKey) throws -> TOTPCode {
    let data = try read(item, key: key, kind: .totp).value
    let credential = try JSON.decode(TOTPCredential.self, from: data, file: "TOTP 凭据")
    return try credential.code(at: unixTime)
  }

  public func registerPasskey(
    ref: Ref, request: PasskeyRequest, metadata: KeyMetadata = KeyMetadata(),
    key: SymmetricKey
  ) throws -> PasskeyRegistration {
    try requireSecret(key)
    try request.validate(registration: true)
    guard try find(ref, includeArchived: true) == nil else {
      throw KagiError(.usage, "Passkey 引用已存在，不能覆盖注册凭据。")
    }
    let credential = try PasskeyCredential.create(for: request)
    let response = try credential.registration(for: request)
    try write(
      ref: ref, value: JSON.encode(credential), issuer: request.rpID, usedIn: nil,
      existing: nil, key: key, metadata: metadata, kind: .passkey)
    return response
  }

  public func assertPasskey(_ item: Listing, request: PasskeyRequest, key: SymmetricKey) throws
    -> PasskeyAssertion
  {
    try request.validate(registration: false)
    let data = try read(item, key: key, kind: .passkey).value
    let credential = try JSON.decode(PasskeyCredential.self, from: data, file: "Passkey 凭据")
    return try credential.assertion(for: request)
  }
}
