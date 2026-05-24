import XCTest
@testable import SSHBackCore

final class CallbackParserTests: XCTestCase {
  func testParsesDirectLoopbackURL() {
    let endpoint = CallbackParser.parse(from: "http://localhost:3921/callback?code=abc")

    XCTAssertEqual(endpoint, CallbackEndpoint(host: "localhost", port: 3921))
  }

  func testParsesNestedRedirectURI() {
    let endpoint = CallbackParser.parse(
      from: "https://login.example.test/start?redirect_uri=http%3A%2F%2F127.0.0.1%3A4888%2Foauth%2Fcallback"
    )

    XCTAssertEqual(endpoint, CallbackEndpoint(host: "127.0.0.1", port: 4888))
  }

  func testRejectsNonLoopbackURL() {
    let endpoint = CallbackParser.parse(from: "https://login.example.test/start?redirect_uri=https%3A%2F%2Fexample.com%3A4888%2Fcallback")

    XCTAssertNil(endpoint)
  }

  func testRejectsReservedPort() {
    let endpoint = CallbackParser.parse(from: "http://localhost:80/callback")

    XCTAssertNil(endpoint)
  }

  func testBrowserShimCommandUsesRemoteBridgePort() throws {
    let command = try BrowserShimCommand.exportCommand(remoteBridgePort: 45123)

    XCTAssertTrue(command.contains("export BROWSER="))
    XCTAssertTrue(command.contains("$HOME/.ssh-back/browser"))
    XCTAssertFalse(command.contains("cat >"))
  }

  func testBrowserShimScriptUsesRemoteBridgePort() throws {
    let script = try BrowserShimCommand.scriptContents(remoteBridgePort: 45123)

    XCTAssertTrue(script.contains("127.0.0.1:45123/open"))
    XCTAssertEqual(try BrowserShimCommand.remoteShimPath(remoteBridgePort: 45123), "~/.ssh-back/browser")
    XCTAssertFalse(script.contains(#"\""#))
  }

  func testBrowserShimInstallScriptWritesExecutableUnderSshBack() throws {
    let script = try BrowserShimCommand.installScript(remoteBridgePort: 45123)

    XCTAssertTrue(script.contains(#"mkdir -p "$HOME/.ssh-back""#))
    XCTAssertTrue(script.contains(#"chmod 700 "$HOME/.ssh-back""#))
    XCTAssertTrue(script.contains(#"cat > "$HOME/.ssh-back/browser""#))
    XCTAssertTrue(script.contains(#"chmod 700 "$HOME/.ssh-back/browser""#))
    XCTAssertTrue(script.contains(#"test -x "$HOME/.ssh-back/browser""#))
    XCTAssertTrue(script.contains(#"rc_file="$HOME/.zshrc""#))
    XCTAssertTrue(script.contains(#"rc_file="$HOME/.bashrc""#))
    XCTAssertTrue(script.contains("ssh-back browser shim"))
  }

  func testBrowserShimInstallScriptDetectsZshAndWritesManagedRcBlock() throws {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let script = try BrowserShimCommand.installScript(remoteBridgePort: 45123)

    let firstOutput = try runInstallScript(script, home: tempDirectory, shell: "/bin/zsh")
    let secondOutput = try runInstallScript(script, home: tempDirectory, shell: "/bin/zsh")
    let rcPath = tempDirectory.appendingPathComponent(".zshrc")
    let rcContents = try String(contentsOf: rcPath, encoding: .utf8)

    XCTAssertTrue(firstOutput.contains("SSH_BACK_ENV_SHELL=zsh"))
    XCTAssertTrue(firstOutput.contains("SSH_BACK_ENV_RC=~/.zshrc"))
    XCTAssertTrue(secondOutput.contains("SSH_BACK_BROWSER_PATH=~/.ssh-back/browser"))
    XCTAssertEqual(count("# >>> ssh-back browser shim >>>", in: rcContents), 1)
    XCTAssertEqual(count(#"export BROWSER="$HOME/.ssh-back/browser""#, in: rcContents), 1)
    XCTAssertEqual(count("# <<< ssh-back browser shim <<<", in: rcContents), 1)
  }

  func testBrowserShimInstallScriptDoesNotDuplicateExistingBrowserExport() throws {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let rcPath = tempDirectory.appendingPathComponent(".zshrc")
    try """
    # existing config
    export BROWSER="/usr/bin/open"
    alias ll='ls -la'
    """.write(to: rcPath, atomically: true, encoding: .utf8)
    let script = try BrowserShimCommand.installScript(remoteBridgePort: 45123)

    _ = try runInstallScript(script, home: tempDirectory, shell: "/bin/zsh")
    _ = try runInstallScript(script, home: tempDirectory, shell: "/bin/zsh")
    let rcContents = try String(contentsOf: rcPath, encoding: .utf8)

    XCTAssertEqual(count(#"export BROWSER="/usr/bin/open""#, in: rcContents), 1)
    XCTAssertEqual(count("# >>> ssh-back browser shim >>>", in: rcContents), 0)
    XCTAssertEqual(count(#"export BROWSER="$HOME/.ssh-back/browser""#, in: rcContents), 0)
    XCTAssertTrue(rcContents.contains("alias ll='ls -la'"))
  }

  func testBrowserShimCommandCanBeEvaluatedByShell() throws {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    let command = try BrowserShimCommand.exportCommand(remoteBridgePort: 45123)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["HOME": tempDirectory.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0)
  }

  private func runInstallScript(_ script: String, home: URL, shell: String) throws -> String {
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]
    process.environment = [
      "HOME": home.path,
      "SHELL": shell,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
    ]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    stdin.fileHandleForWriting.write(Data(script.utf8))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()

    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrText)

    return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  private func count(_ needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
  }
}
