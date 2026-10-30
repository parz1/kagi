import Foundation

/// 库文件夹里每种文件的格式。字段含义见 docs/格式.md。
public enum Format {
  public static let vault = "kagi-vault/1"
  public static let device = "kagi-device/1"
  public static let recovery = "kagi-recovery/1"
  public static let entry = "kagi-entry/1"
  public static let typedEntry = "kagi-entry/2"
  public static let index = "kagi-index/1"
  public static let managedIndex = "kagi-index/2"
  public static let typedIndex = "kagi-index/3"
  public static let catalog = "kagi-catalog/1"
  public static let local = "kagi-local/1"
}

/// vault.json：库 ID 和两把库内密钥的校验值。
public struct VaultFile: Codable, Equatable, Sendable {
  public var format: String
  public var vault: String
  public var created: String
  public var keyCheck: String
  public var indexKeyCheck: String
}

/// HPKE（RFC 9180，P-256 + HKDF-SHA256 + AES-256-GCM）的一次封装。
public struct HPKEBox: Codable, Equatable, Sendable {
  public var enc: String
  public var ciphertext: String
}

/// keys/<设备>.json：库密钥和索引密钥分别包给这台设备的两把 Secure Enclave 密钥。
public struct DeviceFile: Codable, Equatable, Sendable {
  public var format: String
  public var vault: String
  public var device: String
  public var name: String
  public var created: String
  public var secretPublicKey: String
  public var indexPublicKey: String
  public var secretWrap: HPKEBox
  public var indexWrap: HPKEBox
}

/// keys/recovery.json：库密钥和索引密钥用恢复密钥派生的密钥加密（AES-256-GCM）。
public struct RecoveryFile: Codable, Equatable, Sendable {
  public var format: String
  public var vault: String
  public var secretWrap: String
  public var indexWrap: String
}

/// entries/<条目>/<版本>.kagi：一条值的一个版本，用库密钥加密。
public struct EntryFile: Codable, Equatable, Sendable {
  public var format: String
  public var vault: String
  public var entry: String
  public var version: Int
  public var created: String
  public var box: String
}

/// EntryFile 解密后的内容。value 是 Base64，任意字节都能存。
public struct EntryPlain: Codable, Equatable, Sendable {
  public var ref: String
  public var value: String
  public var kind: CredentialKind

  public init(ref: String, value: String, kind: CredentialKind = .secret) {
    self.ref = ref
    self.value = value
    self.kind = kind
  }

  enum CodingKeys: String, CodingKey { case ref, value, kind }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    ref = try values.decode(String.self, forKey: .ref)
    value = try values.decode(String.self, forKey: .value)
    kind = try values.decodeIfPresent(CredentialKind.self, forKey: .kind) ?? .secret
  }
}

/// index/<条目>.kagi：一条的名字和元数据，用索引密钥加密。
public struct IndexFile: Codable, Equatable, Sendable {
  public var format: String
  public var vault: String
  public var entry: String
  public var box: String
}

/// IndexFile 解密后的内容。
public struct IndexRecord: Codable, Equatable, Sendable {
  public var ref: String
  public var issuer: String?
  public var usedIn: String?
  public var created: String
  public var updated: String
  public var latestVersion: Int
  public var metadata: KeyMetadata
  public var kind: CredentialKind

  public init(
    ref: String, issuer: String?, usedIn: String?, created: String, updated: String,
    latestVersion: Int, metadata: KeyMetadata = KeyMetadata(), kind: CredentialKind = .secret
  ) {
    self.ref = ref
    self.issuer = issuer
    self.usedIn = usedIn
    self.created = created
    self.updated = updated
    self.latestVersion = latestVersion
    self.metadata = metadata
    self.kind = kind
  }

  enum CodingKeys: String, CodingKey {
    case ref, issuer, usedIn, created, updated, latestVersion, metadata, kind
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    ref = try values.decode(String.self, forKey: .ref)
    issuer = try values.decodeIfPresent(String.self, forKey: .issuer)
    usedIn = try values.decodeIfPresent(String.self, forKey: .usedIn)
    created = try values.decode(String.self, forKey: .created)
    updated = try values.decode(String.self, forKey: .updated)
    latestVersion = try values.decode(Int.self, forKey: .latestVersion)
    metadata = try values.decodeIfPresent(KeyMetadata.self, forKey: .metadata) ?? KeyMetadata()
    kind = try values.decodeIfPresent(CredentialKind.self, forKey: .kind) ?? .secret
  }
}

/// 附加数据和 HPKE info：把每段密文绑定到它所在的库、条目和版本。
public enum Binding {
  public static func entry(
    vault: String, entry: String, version: Int, created: String, format: String = Format.entry
  ) -> Data {
    Data("\(format)|\(vault)|\(entry)|\(version)|\(created)".utf8)
  }

  public static func index(vault: String, entry: String, format: String = Format.index) -> Data {
    Data("\(format)|\(vault)|\(entry)".utf8)
  }

  public static func catalog(vault: String) -> Data {
    Data("\(Format.catalog)|\(vault)".utf8)
  }

  public static func recovery(vault: String, purpose: KeyPurpose) -> Data {
    Data("\(Format.recovery)|\(vault)|\(purpose.rawValue)".utf8)
  }

  public static func device(vault: String, device: String, purpose: KeyPurpose) -> Data {
    Data("\(Format.device)|\(vault)|\(device)|\(purpose.rawValue)".utf8)
  }

  public static func keyCheck(vault: String, purpose: KeyPurpose) -> Data {
    Data("kagi-key-check/1|\(vault)|\(purpose.rawValue)".utf8)
  }
}

/// 库里的两把对称密钥：secret 加密值，index 加密名字和元数据。
public enum KeyPurpose: String, Sendable {
  case secret
  case index
}

enum Timestamp {
  static func now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
  }

  static func parse(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

enum JSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data, file: String) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw KagiError(.dataError, "\(file) 的内容读不懂，可能坏了或者被改过。")
    }
  }
}
