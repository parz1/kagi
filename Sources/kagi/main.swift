import Darwin
import Foundation
import KagiCore

/// 很小的参数解析：选项可以写成 `--name 值` 或 `--name=值`。
struct ArgParser {
  var items: [String]

  init(_ items: [String]) {
    self.items = items
  }

  mutating func flag(_ name: String) -> Bool {
    guard let index = items.firstIndex(of: name) else { return false }
    items.remove(at: index)
    return true
  }

  /// 取出第一次出现的选项值；同一个选项可以反复取。
  mutating func value(for name: String) throws -> String? {
    if let index = items.firstIndex(of: name) {
      guard index + 1 < items.count else { throw KagiError(.usage, "\(name) 后面要跟一个值。") }
      let value = items[index + 1]
      items.removeSubrange(index...(index + 1))
      return value
    }
    if let index = items.firstIndex(where: { $0.hasPrefix(name + "=") }) {
      let value = String(items[index].dropFirst(name.count + 1))
      items.remove(at: index)
      return value
    }
    return nil
  }

  mutating func positionals() throws -> [String] {
    if let unknown = items.first(where: { $0.hasPrefix("-") }) {
      throw KagiError(.usage, "不认识的选项 \(unknown)。", hint: "看用法：kagi help")
    }
    defer { items = [] }
    return items
  }

  mutating func finish() throws {
    if let first = items.first {
      throw KagiError(.usage, "不认识的参数 \(first)。", hint: "看用法：kagi help")
    }
  }
}

signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())

do {
  switch command {
  case "init": try Commands.initVault(rest)
  case "set": try Commands.set(rest)
  case "run": exit(try Commands.run(rest))
  case "ls": try Commands.list(rest)
  case "where": try Commands.whereIs(rest)
  case "log": try Commands.log(rest)
  case "guide": Term.print(Texts.guide)
  case "recover": try Commands.recover(rest)
  case "help", "-h", "--help": Term.print(Texts.help)
  case "version", "-v", "--version": Term.print(Texts.version)
  #if DEBUG
    case "_debug-init": try Commands.debugInit(rest)
  #endif
  case "_clear-clipboard":
    Clipboard.clearIfUnchanged(
      changeCount: rest.first.flatMap { Int($0) } ?? -1,
      after: rest.dropFirst().first.flatMap { Int($0) } ?? 30)
  default:
    throw KagiError(.usage, "不认识的命令 \(command)。", hint: "看全部命令：kagi help")
  }
  exit(0)
} catch let error as KagiError {
  Term.say("kagi：\(error.message)", .bad)
  if let hint = error.hint { Term.say(hint) }
  exit(error.code.rawValue)
} catch let failure as KeyFailure {
  let error = Kagi.describe(failure, action: .read, byAgent: false)
  Term.say("kagi：\(error.message)", .bad)
  exit(error.code.rawValue)
} catch {
  Term.say("kagi：出错了：\(error.localizedDescription)", .bad)
  exit(ExitCode.software.rawValue)
}
