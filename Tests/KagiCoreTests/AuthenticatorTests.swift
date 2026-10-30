import CryptoKit
import Foundation
import XCTest

@testable import KagiCore

final class TOTPTests: XCTestCase {
  // RFC 6238 Appendix B；每种算法使用规范规定的密钥长度。
  func testRFC6238AllAlgorithmsAndTimestamps() throws {
    let times: [UInt64] = [
      59, 1_111_111_109, 1_111_111_111, 1_234_567_890, 2_000_000_000, 20_000_000_000,
    ]
    let cases: [(OTPAlgorithm, String, [String])] = [
      (
        .sha1, "12345678901234567890",
        ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"]
      ),
      (
        .sha256, "12345678901234567890123456789012",
        ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"]
      ),
      (
        .sha512, String(repeating: "1234567890", count: 6) + "1234",
        ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"]
      ),
    ]
    for (algorithm, secret, expected) in cases {
      let credential = try TOTPCredential(
        secret: Data(secret.utf8), algorithm: algorithm, digits: 8)
      for (time, code) in zip(times, expected) {
        XCTAssertEqual(try credential.code(at: time).code, code, "\(algorithm) at \(time)")
      }
    }
  }

  func testRFC4226CountersAndPeriodBoundaries() throws {
    let credential = try TOTPCredential(secret: Data("12345678901234567890".utf8))
    let codes = [
      "755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871",
      "520489",
    ]
    for (counter, code) in codes.enumerated() {
      XCTAssertEqual(try credential.code(at: UInt64(counter * 30)).code, code)
    }
    XCTAssertEqual(try credential.code(at: 29).validUntil, 30)
    XCTAssertEqual(try credential.code(at: 30).validFrom, 30)
    XCTAssertEqual(try credential.code(at: 30).validUntil, 60)
    XCTAssertThrowsError(try credential.code(at: UInt64.max))
  }

  func testRFC4648AlphabetPaddingAndCanonicalBits() throws {
    for (encoded, plain) in [
      ("MY======", "f"), ("MZXQ====", "fo"), ("MZXW6===", "foo"),
      ("MZXW6YQ=", "foob"), ("MZXW6YTB", "fooba"), ("MZXW6YTBOI======", "foobar"),
    ] {
      XCTAssertEqual(try OTPBase32.decode(encoded.lowercased()), Data(plain.utf8))
      XCTAssertEqual(
        try OTPBase32.decode(encoded.replacingOccurrences(of: "=", with: "")), Data(plain.utf8))
    }
    for value in ["", "A", "MZ", "MY=", "MY======A", "M0======", "ß", "MY ======"] {
      XCTAssertThrowsError(try OTPBase32.decode(value), value)
    }
  }

  func testURIImportAndInvalidParameters() throws {
    let seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    let credential = try TOTPCredential.parse(
      "otpauth://totp/Demo:alice%40example.test?secret=\(seed)&issuer=Demo&algorithm=SHA1&digits=8&period=30"
    )
    XCTAssertEqual(credential.account, "alice@example.test")
    XCTAssertEqual(credential.issuer, "Demo")
    XCTAssertEqual(try credential.code(at: 59).code, "94287082")
    for uri in [
      "otpauth://hotp/Demo?secret=\(seed)", "otpauth://totp/Demo?secret=\(seed)&secret=\(seed)",
      "otpauth://totp/Demo:alice?secret=\(seed)&issuer=Other",
      "otpauth://totp/Demo?secret=\(seed)&period=0",
      "otpauth://totp/Demo?secret=\(seed)&digits=9",
      "otpauth://totp/Demo?secret=\(seed)&algorithm=MD5",
      "otpauth://totp/Demo?secret=\(seed)&unknown=1",
    ] {
      XCTAssertThrowsError(try TOTPCredential.parse(uri))
    }
    XCTAssertThrowsError(try TOTPCredential(secret: Data()))
  }
}

final class PasskeyTests: XCTestCase {
  func request(
    registration: Bool = true, rp: String = "example.test", origin: String? = nil,
    challenge: Data = Data(repeating: 7, count: 32)
  ) -> PasskeyRequest {
    PasskeyRequest(
      rpID: rp, origin: origin ?? "https://\(rp)", challenge: Base64URL.encode(challenge),
      userHandle: registration ? Base64URL.encode(Data("alice-id".utf8)) : nil,
      userName: registration ? "alice" : nil)
  }

  func testES256AssertionAndClientDataBinding() throws {
    let credential = try PasskeyCredential.create(for: request())
    let result = try credential.assertion(for: request(registration: false))
    let clientData = try Base64URL.decode(result.response.clientDataJSON)
    let authData = try Base64URL.decode(result.response.authenticatorData)
    XCTAssertEqual(authData.count, 37)
    XCTAssertEqual(authData.prefix(32), Data(SHA256.hash(data: Data("example.test".utf8))))
    XCTAssertEqual(authData[32], 0x0D)
    XCTAssertEqual(authData.suffix(4), Data(repeating: 0, count: 4))
    let json = try JSONSerialization.jsonObject(with: clientData) as! [String: Any]
    XCTAssertEqual(json["origin"] as? String, "https://example.test")
    XCTAssertEqual(json["type"] as? String, "webauthn.get")
    XCTAssertEqual(json["challenge"] as? String, request(registration: false).challenge)
    XCTAssertEqual(json["crossOrigin"] as? Bool, false)
    let publicKey = try P256.Signing.PrivateKey(rawRepresentation: credential.privateKey).publicKey
    let signature = try P256.Signing.ECDSASignature(
      derRepresentation: Base64URL.decode(result.response.signature))
    XCTAssertTrue(
      publicKey.isValidSignature(signature, for: authData + Data(SHA256.hash(data: clientData))))
    let tampered = Data("changed challenge or origin".utf8)
    XCTAssertFalse(
      publicKey.isValidSignature(signature, for: authData + Data(SHA256.hash(data: tampered))))
    var wrongRP = authData
    wrongRP[0] ^= 1
    XCTAssertFalse(
      publicKey.isValidSignature(signature, for: wrongRP + Data(SHA256.hash(data: clientData))))
    XCTAssertEqual(result.id, Base64URL.encode(credential.credentialID))
    XCTAssertEqual(result.response.userHandle, Base64URL.encode(credential.userHandle))
  }

  func testRegistrationHasNoPrivateKeyAndCredentialsAreUnique() throws {
    let one = try PasskeyCredential.create(for: request())
    let two = try PasskeyCredential.create(for: request())
    XCTAssertNotEqual(one.credentialID, two.credentialID)
    let registration = try one.registration(for: request())
    let text = String(decoding: try JSONEncoder().encode(registration), as: UTF8.self)
    XCTAssertFalse(text.contains("privateKey"))
    XCTAssertFalse(text.contains(one.privateKey.base64EncodedString()))
    XCTAssertEqual(registration.type, "public-key")
    let client =
      try JSONSerialization.jsonObject(with: Base64URL.decode(registration.response.clientDataJSON))
      as! [String: Any]
    XCTAssertEqual(client["type"] as? String, "webauthn.create")
    XCTAssertThrowsError(
      try one.registration(for: request(challenge: Data(repeating: 1, count: 1))))
  }

  func testOriginRPAndChallengeRejectUnsafeOrUnsupportedRequests() throws {
    let credential = try PasskeyCredential.create(for: request())
    for origin in [
      "http://example.test", "https://example.test/", "https://example.test/path",
      "https://evil.test", "https://example.test.evil", "https://user@example.test",
      "https://example.test:443",
      "https://example.test?x=1", "https://example.test#fragment",
    ] {
      XCTAssertThrowsError(
        try credential.assertion(for: request(registration: false, origin: origin)), origin)
    }
    XCTAssertThrowsError(
      try credential.assertion(for: request(registration: false, rp: "evil.test")))
    XCTAssertThrowsError(try request(challenge: Data()).validate(registration: true))
    XCTAssertNoThrow(
      try request(rp: "localhost", origin: "http://localhost:8080").validate(registration: true))
    let invalid = PasskeyRequest(
      rpID: "example.test", origin: "https://example.test", challenge: request().challenge,
      userHandle: Base64URL.encode(Data(repeating: 1, count: 65)), userName: "alice")
    XCTAssertThrowsError(try invalid.validate(registration: true))
    let unsupported = Data("{\"rpID\":\"example.test\",\"excludeCredentials\":[]}".utf8)
    XCTAssertThrowsError(try PasskeyRequest.parse(unsupported))
    for value in ["AA=", "AB", "A", "+/=="] { XCTAssertThrowsError(try Base64URL.decode(value)) }
  }
}

final class AuthenticatorVaultTests: XCTestCase {
  var root: URL!
  var session: Session!
  var key: SymmetricKey!
  var pending: PendingVault!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kagi-auth-\(UUID().uuidString)")
    let backend = SoftwareBackend()
    let local = LocalStore(dir: root.appendingPathComponent("local"))
    pending = try Kagi.prepareInit(
      at: root.appendingPathComponent("vault"), deviceName: "Fake Mac",
      backend: backend, reason: { $0 })
    try pending.commit(local: local)
    session = try Session(local: local, backend: backend)
    key = try session.unlock(reason: "FAKE test consent", action: .write, byAgent: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  func testTypedStorageCannotExportSeedAsOrdinarySecretAndRepairPreservesType() throws {
    let ref = try Ref("demo/otp")
    let credential = try TOTPCredential(secret: Data("12345678901234567890".utf8), digits: 8)
    try session.importTOTP(
      ref: ref, credential: credential, metadata: KeyMetadata(tags: ["auth"]), key: key)
    let item = try XCTUnwrap(session.find(ref))
    XCTAssertEqual(item.record.kind, .totp)
    XCTAssertEqual(try session.store.readEntry(item.entry, version: 1).format, Format.typedEntry)
    XCTAssertEqual(try session.store.indexFiles().first?.format, Format.typedIndex)
    XCTAssertThrowsError(try session.read(item, key: key))
    XCTAssertEqual(try session.totpCode(item, at: 59, key: key).code, "94287082")
    XCTAssertThrowsError(
      try session.write(
        ref: ref, value: Data("FAKE".utf8), issuer: nil, usedIn: nil, existing: item, key: key))
    try FileManager.default.removeItem(
      at: session.store.indexDir.appendingPathComponent(item.entry + ".kagi"))
    _ = try session.repairIndex(key: key)
    let repaired = try XCTUnwrap(session.find(ref, includeArchived: true))
    XCTAssertEqual(repaired.record.kind, .totp)
    XCTAssertTrue(repaired.record.metadata.archived)
    var metadata = repaired.record.metadata
    metadata.archived = false
    try session.updateKey(
      repaired, metadata: metadata, issuer: repaired.record.issuer, usedIn: nil, key: key)
    XCTAssertEqual(
      try session.totpCode(XCTUnwrap(session.find(ref)), at: 59, key: key).code, "94287082")
  }

  func testPasskeyRegistrationAssertionsAndRecoveryKeepSameCredential() throws {
    let ref = try Ref("demo/passkey")
    let request = PasskeyTests().request()
    let registration = try session.registerPasskey(
      ref: ref, request: request,
      metadata: KeyMetadata(tags: ["auth"]), key: key)
    let item = try XCTUnwrap(session.find(ref))
    XCTAssertEqual(item.record.kind, .passkey)
    XCTAssertThrowsError(try session.read(item, key: key))
    let original = try JSONDecoder().decode(
      PasskeyCredential.self,
      from: session.read(item, key: key, kind: .passkey).value)
    let originalPublicKey = try P256.Signing.PrivateKey(rawRepresentation: original.privateKey)
      .publicKey
    XCTAssertThrowsError(try session.registerPasskey(ref: ref, request: request, key: key))
    let assertionRequest = PasskeyTests().request(registration: false)
    XCTAssertEqual(
      try session.assertPasskey(item, request: assertionRequest, key: key).id, registration.id)
    let local = LocalStore(dir: root.appendingPathComponent("other-device"))
    _ = try Kagi.recover(
      at: pending.store.root, recoveryKey: pending.recoveryKey, deviceName: "Fake other Mac",
      backend: SoftwareBackend(), local: local, reason: { $0 })
    let recovered = try Session(local: local, backend: SoftwareBackend())
    let newKey = try recovered.unlock(reason: "fake", action: .read, byAgent: false)
    let restored = try XCTUnwrap(recovered.find(ref))
    let restoredAssertion = try recovered.assertPasskey(
      restored, request: assertionRequest, key: newKey)
    XCTAssertEqual(restoredAssertion.id, registration.id)
    let restoredSignature = try P256.Signing.ECDSASignature(
      derRepresentation: Base64URL.decode(restoredAssertion.response.signature))
    let restoredMessage =
      try Base64URL.decode(restoredAssertion.response.authenticatorData)
      + Data(SHA256.hash(data: Base64URL.decode(restoredAssertion.response.clientDataJSON)))
    XCTAssertTrue(originalPublicKey.isValidSignature(restoredSignature, for: restoredMessage))
    XCTAssertEqual(restored.record.metadata.tags, ["auth"])
    var metadata = restored.record.metadata
    metadata.archived = true
    try recovered.updateKey(
      restored, metadata: metadata, issuer: restored.record.issuer, usedIn: nil, key: newKey)
    XCTAssertThrowsError(
      try recovered.assertPasskey(restored, request: assertionRequest, key: newKey))
  }

  func testIndexTypeTamperingCannotTurnSeedIntoOrdinarySecret() throws {
    let ref = try Ref("demo/otp")
    try session.importTOTP(
      ref: ref, credential: TOTPCredential(secret: Data("12345678901234567890".utf8)), key: key)
    let item = try XCTUnwrap(session.find(ref))
    var forged = item.record
    forged.kind = .secret
    try session.saveIndex(entry: item.entry, record: forged)
    let claimedSecret = try XCTUnwrap(session.find(ref))
    XCTAssertThrowsError(try session.read(claimedSecret, key: key))
    XCTAssertThrowsError(try session.repairIndex(key: key))
  }
}
