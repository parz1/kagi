import Darwin
import Foundation

/// 启动子进程：把值放进环境变量或标准输入，子进程的 stdout、stderr 经过打码再写出去。
public enum Runner {
  /// 在授权之前解析 PATH，执行时使用同一个绝对路径。
  public static func resolveExecutable(_ name: String) throws -> String {
    let candidates: [String]
    if name.contains("/") {
      candidates = [name]
    } else {
      candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        .split(separator: ":", omittingEmptySubsequences: false)
        .map { ($0.isEmpty ? "." : String($0)) + "/" + name }
    }
    for candidate in candidates {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
        !isDirectory.boolValue, access(candidate, X_OK) == 0
      {
        return URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
      }
    }
    throw KagiError(.commandNotFound, "找不到可执行命令 \(name)。")
  }

  /// 返回子进程的退出码；被信号杀掉时返回 128 + 信号。
  public static func run(
    argv: [String], extraEnvironment: [String: String], stdinData: Data?,
    values: [(ref: String, value: Data)]
  ) throws -> Int32 {
    precondition(!argv.isEmpty)

    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extraEnvironment { environment[key] = value }

    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    var inPipe: [Int32] = [-1, -1]
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
      throw KagiError(.software, "建不了管道：\(String(cString: strerror(errno)))")
    }
    if stdinData != nil, pipe(&inPipe) != 0 {
      throw KagiError(.software, "建不了管道：\(String(cString: strerror(errno)))")
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if stdinData != nil {
      posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
      posix_spawn_file_actions_addclose(&actions, inPipe[1])
    }
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
    for fd in [outPipe[0], errPipe[0], outPipe[1], errPipe[1]] {
      posix_spawn_file_actions_addclose(&actions, fd)
    }
    if stdinData != nil { posix_spawn_file_actions_addclose(&actions, inPipe[0]) }

    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      cArgs.forEach { free($0) }
      cEnv.forEach { free($0) }
    }

    // 子进程跑着的时候，Ctrl-C 交给子进程（同一个进程组），kagi 自己不退，等它收尾。
    let oldInt = signal(SIGINT, SIG_IGN)
    let oldQuit = signal(SIGQUIT, SIG_IGN)
    defer {
      signal(SIGINT, oldInt)
      signal(SIGQUIT, oldQuit)
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGHUP] { sigaddset(&defaults, sig) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var pid: pid_t = 0
    let status = posix_spawnp(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
    close(outPipe[1])
    close(errPipe[1])
    if stdinData != nil { close(inPipe[0]) }
    guard status == 0 else {
      close(outPipe[0])
      close(errPipe[0])
      if stdinData != nil { close(inPipe[1]) }
      if status == ENOENT {
        throw KagiError(.commandNotFound, "找不到命令 \(argv[0])。", hint: "检查命令名，或者写完整路径。")
      }
      throw KagiError(.software, "启动不了 \(argv[0])：\(String(cString: strerror(status)))")
    }

    // 收到 TERM、HUP 时转给子进程。
    let forwarded = [SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler { kill(pid, sig) }
      source.resume()
      return source
    }
    defer {
      forwarded.forEach { $0.cancel() }
      signal(SIGTERM, SIG_DFL)
      signal(SIGHUP, SIG_DFL)
    }

    let group = DispatchGroup()
    pump(from: outPipe[0], to: STDOUT_FILENO, redactor: Redactor(values: values), group: group)
    pump(from: errPipe[0], to: STDERR_FILENO, redactor: Redactor(values: values), group: group)

    if let data = stdinData {
      let fd = inPipe[1]
      DispatchQueue.global().async {
        data.withUnsafeBytes { raw in
          var offset = 0
          while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { break }
            offset += n
          }
        }
        close(fd)
      }
    }

    var waitStatus: Int32 = 0
    while waitpid(pid, &waitStatus, 0) == -1 && errno == EINTR {}
    // 子进程退出后，最多再等 2 秒把输出读完（它开的后台进程可能还拿着管道）。
    _ = group.wait(timeout: .now() + 2)

    let low = waitStatus & 0x7F
    if low == 0 { return (waitStatus >> 8) & 0xFF }
    return 128 + low
  }

  static func pump(from source: Int32, to target: Int32, redactor: Redactor, group: DispatchGroup) {
    group.enter()
    DispatchQueue.global().async {
      var buffer = [UInt8](repeating: 0, count: 16384)
      while true {
        let n = read(source, &buffer, buffer.count)
        if n > 0 {
          writeAll(target, redactor.feed(Data(buffer[0..<n])))
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
      writeAll(target, redactor.finish())
      close(source)
      group.leave()
    }
  }

  static func writeAll(_ fd: Int32, _ data: Data) {
    guard !data.isEmpty else { return }
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        offset += n
      }
    }
  }
}
