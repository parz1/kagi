import XCTest

@testable import KagiCore

final class EnvironmentPolicyTests: XCTestCase {
  func testCodeLoadingVariablesAreRisky() {
    for name in [
      "NODE_OPTIONS", "PYTHONPATH", "BASH_ENV", "ZDOTDIR", "RUBYOPT", "PERL5OPT",
      "JAVA_TOOL_OPTIONS", "GIT_SSH_COMMAND", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH",
      "LD_PRELOAD", "BASH_FUNC_ls%%", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "LUA_INIT_5_4",
      "npm_config_script_shell", "NPM_CONFIG_NODE_OPTIONS",
    ] {
      XCTAssertTrue(EnvironmentPolicy.isRisky(name), name)
    }
  }

  func testOrdinaryVariablesAreKept() {
    for name in [
      "PATH", "HOME", "USER", "LANG", "TERM", "SHELL", "TMPDIR", "NODE_ENV", "ENV", "LDFLAGS",
      "PYTHONUNBUFFERED", "GIT_AUTHOR_NAME", "NPM_TOKEN", "node_options",
    ] {
      XCTAssertFalse(EnvironmentPolicy.isRisky(name), name)
    }
  }

  func testFilterRemovesRiskyVariablesUnlessKept() {
    let inherited = [
      "PATH": "/usr/bin:/bin",
      "NODE_OPTIONS": "--require=/tmp/fake-hook.js",
      "DYLD_INSERT_LIBRARIES": "/tmp/fake.dylib",
      "PYTHONPATH": "/tmp/fake-site",
    ]
    let filtered = EnvironmentPolicy.filter(inherited, keep: ["PYTHONPATH", "RUBYOPT"])
    XCTAssertEqual(
      filtered.environment, ["PATH": "/usr/bin:/bin", "PYTHONPATH": "/tmp/fake-site"])
    XCTAssertEqual(filtered.removed, ["DYLD_INSERT_LIBRARIES", "NODE_OPTIONS"])
    // RUBYOPT 不在继承环境里，不出现在保留列表中。
    XCTAssertEqual(filtered.kept, [EnvironmentPolicy.Kept(name: "PYTHONPATH", value: "/tmp/fake-site")])
  }

  func testFilterWithNothingRiskyIsIdentity() {
    let inherited = ["PATH": "/usr/bin", "HOME": "/Users/fake"]
    let filtered = EnvironmentPolicy.filter(inherited, keep: [])
    XCTAssertEqual(filtered.environment, inherited)
    XCTAssertEqual(filtered.removed, [])
    XCTAssertEqual(filtered.kept, [])
  }
}
