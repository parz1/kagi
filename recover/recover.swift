// recover.swift：不经过 kagi，用恢复密钥把库里每一条的最新版本解成明文文件。
// 只在 kagi 坏了、装不上的时候用。它只按 docs/格式.md 实现，不和 kagi 共用任何代码。
//
// 用法：swift recover.swift --vault <库的文件夹> --out <输出文件夹>
//
// 输出文件夹必须不存在或为空；里面的文件是明文，用完请删除。
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("recover：\(message)\n".utf8))
  exit(1)
}

func option(_ name: String) -> String? {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  return args[i + 1]
}

guard let vaultPath = option("--vault"), let outPath = option("--out") else {
  fail("用法：swift recover.swift --vault <库的文件夹> --out <输出文件夹>")
}
let vaultDir = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true)
let outDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath, isDirectory: true)

func readJSON(_ url: URL) -> [String: Any] {
  guard let data = try? Data(contentsOf: url),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { fail("读不了 \(url.path)") }
  return object
}

func string(_ object: [String: Any], _ key: String, _ file: String) -> String {
  guard let value = object[key] as? String else { fail("\(file) 里缺少 \(key)") }
  return value
}

// 1. 库 ID 和恢复密钥包装。
let vaultFile = readJSON(vaultDir.appendingPathComponent("vault.json"))
guard string(vaultFile, "format", "vault.json") == "kagi-vault/1" else {
  fail("vault.json 的格式版本不认得")
}
let vaultID = string(vaultFile, "vault", "vault.json")
let recoveryFile = readJSON(vaultDir.appendingPathComponent("keys/recovery.json"))
guard string(recoveryFile, "vault", "keys/recovery.json") == vaultID else {
  fail("keys/recovery.json 不属于这个库")
}

// 2. 读恢复密钥并解码：Crockford Base32，忽略大小写、横线、空格；O 当 0，I 和 L 当 1。
var buffer = [CChar](repeating: 0, count: 512)
guard readpassphrase("恢复密钥（输入时不显示）：", &buffer, buffer.count, 0) != nil else { fail("没有读到恢复密钥") }
let typed = String(cString: buffer)
memset_s(&buffer, buffer.count, 0, buffer.count)

let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
var bits = 0
var acc = 0
var decoded = Data()
for raw in typed.uppercased() where raw != "-" && raw != " " {
  let c: Character = raw == "O" ? "0" : (raw == "I" || raw == "L") ? "1" : raw
  guard let v = alphabet.firstIndex(of: c) else { fail("恢复密钥里有不认识的字符") }
  acc = (acc << 5) | v
  bits += 5
  if bits >= 8 {
    decoded.append(UInt8((acc >> (bits - 8)) & 0xFF))
    bits -= 8
  }
  acc &= (1 << bits) - 1
}
guard decoded.count == 20 else { fail("恢复密钥的长度不对，应该是 8 组、每组 4 个字符") }
let secret = decoded.prefix(18)
var checksumHasher = SHA256()
checksumHasher.update(data: Data("kagi-recovery-checksum/1".utf8))
checksumHasher.update(data: secret)
guard Data(checksumHasher.finalize().prefix(2)) == decoded.suffix(2) else {
  fail("恢复密钥不对：校验没通过，可能有一位抄错了")
}

// 3. 恢复密钥 → 加密密钥 → 库密钥。
let kek = HKDF<SHA256>.deriveKey(
  inputKeyMaterial: SymmetricKey(data: secret),
  salt: Data("kagi-recovery/1|\(vaultID)".utf8),
  info: Data("kagi recovery key-encryption key".utf8),
  outputByteCount: 32)

func open(_ base64: String, _ key: SymmetricKey, _ binding: String) -> Data? {
  guard let combined = Data(base64Encoded: base64),
    let box = try? AES.GCM.SealedBox(combined: combined)
  else {
    return nil
  }
  return try? AES.GCM.open(box, using: key, authenticating: Data(binding.utf8))
}

guard
  let vaultKeyData = open(
    string(recoveryFile, "secretWrap", "keys/recovery.json"), kek,
    "kagi-recovery/1|\(vaultID)|secret")
else { fail("这把恢复密钥解不开这个库") }
let vaultKey = SymmetricKey(data: vaultKeyData)

// 4. 每个条目取版本号最大的文件解密。
let fm = FileManager.default
if fm.fileExists(atPath: outDir.path),
  !((try? fm.contentsOfDirectory(atPath: outDir.path)) ?? []).isEmpty
{
  fail("\(outDir.path) 已经存在而且不是空的，换一个输出位置")
}

let entriesDir = vaultDir.appendingPathComponent("entries", isDirectory: true)
guard let entryNames = try? fm.contentsOfDirectory(atPath: entriesDir.path) else {
  fail("读不了 entries 目录")
}
let entryIDs = entryNames.filter { !$0.hasPrefix(".") }.sorted()
var exports: [(path: String, ref: String, kind: String, value: Data)] = []
for entryID in entryIDs {
  guard entryID.count == 16, entryID.allSatisfy({ "0123456789abcdefghjkmnpqrstvwxyz".contains($0) })
  else {
    fail("条目 ID 不合法：\(entryID)")
  }
  let dir = entriesDir.appendingPathComponent(entryID, isDirectory: true)
  guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else {
    fail("读不了条目目录：\(entryID)")
  }
  var versions: [Int] = []
  for file in files where file.hasSuffix(".kagi") && !file.hasPrefix(".") {
    guard let version = Int(file.dropLast(5)), version > 0,
      file == String(format: "%04ld.kagi", version)
    else { fail("版本文件冲突或异常：\(entryID)/\(file)") }
    versions.append(version)
  }
  guard let version = versions.max() else { fail("条目没有版本：\(entryID)") }
  let name = String(format: "%04ld.kagi", version)
  let file = readJSON(dir.appendingPathComponent(name))
  guard string(file, "vault", name) == vaultID, string(file, "entry", name) == entryID,
    (file["version"] as? Int) == version
  else { fail("entries/\(entryID)/\(name) 和它的位置对不上") }
  let created = string(file, "created", name)
  let format = string(file, "format", name)
  guard ["kagi-entry/1", "kagi-entry/2"].contains(format) else { fail("不支持的值格式") }
  guard
    let plain = open(
      string(file, "box", name), vaultKey,
      "\(format)|\(vaultID)|\(entryID)|\(version)|\(created)"),
    let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
    let ref = object["ref"] as? String, let valueText = object["value"] as? String,
    let value = Data(base64Encoded: valueText)
  else { fail("entries/\(entryID)/\(name) 解不开，可能被改过") }

  let kind = object["kind"] as? String ?? "secret"
  guard ["secret", "totp", "passkey"].contains(kind),
    (format == "kagi-entry/2") == (kind != "secret")
  else { fail("凭据格式或类型不匹配") }
  let segments = ref.split(separator: "/", omittingEmptySubsequences: false)
  guard !ref.isEmpty, ref.count <= 200,
    segments.allSatisfy({ segment in
      guard let first = segment.first, segment.count <= 64,
        first.isASCII && (first.isLowercase || first.isNumber)
      else { return false }
      return segment.allSatisfy {
        $0.isASCII && ($0.isLowercase || $0.isNumber || "._-".contains($0))
      }
    })
  else { fail("条目引用名不合法：\(entryID)") }
  // 每个条目独立目录，避免 foo 与 foo.txt、大小写和目录前缀导致的覆盖。
  let outputName = String(segments.last!)
  exports.append((entryID + "/" + outputName, ref, kind, value))
}

// 所有条目验证完毕才写明文。目标文件绝不覆盖。
try fm.createDirectory(
  at: outDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path)
for item in exports {
  let target = outDir.appendingPathComponent(item.path)
  try fm.createDirectory(
    at: target.deletingLastPathComponent(), withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard fd >= 0 else { fail("无法排他创建恢复文件：\(item.path)") }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  try handle.write(contentsOf: item.value)
  try handle.close()
}
let manifest = exports.map { ["ref": $0.ref, "file": $0.path, "kind": $0.kind] }
let manifestData = try JSONSerialization.data(
  withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(
  to: outDir.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
try fm.setAttributes(
  [.posixPermissions: 0o600], ofItemAtPath: outDir.appendingPathComponent("manifest.json").path)
print("解出 \(exports.count) 条，写到 \(outDir.path)/（权限 0700）：")
exports.forEach { print("  \($0.ref) → \($0.path)") }
print("这些是明文文件，用完请删除：rm -r \(outDir.path)")
