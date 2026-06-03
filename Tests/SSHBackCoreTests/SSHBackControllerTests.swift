import XCTest
@testable import SSHBackCore

final class SSHBackControllerTests: XCTestCase {
  func testStartSessionRecordsMenuBarConnection() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let snapshot = controller.snapshot()
    XCTAssertEqual(snapshot.menuBar.status, .connected)
    XCTAssertEqual(snapshot.activeSession?.targetName, "devbox")
    XCTAssertEqual(snapshot.activeSession?.status, .ready)
    XCTAssertEqual(snapshot.tunnels.first?.purpose, .controlBridge)
    XCTAssertEqual(processManager.controlTunnelRequests.count, 1)
    XCTAssertEqual(processManager.browserShimInstallRequests.count, 1)
    XCTAssertEqual(snapshot.activeSession?.browserShimPath, "~/.ssh-back/browser")
    XCTAssertNotNil(snapshot.activeSession?.browserShimInstalledAt)
    XCTAssertEqual(snapshot.activeSession?.browserEnvShell, "zsh")
    XCTAssertEqual(snapshot.activeSession?.browserEnvRcPath, "~/.zshrc")
  }

  func testStartSessionUsesExplicitRemoteAgentPort() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox", remoteAgentPort: 45123)
    defer { controller.disconnect() }

    let snapshot = controller.snapshot()
    XCTAssertEqual(snapshot.activeSession?.remoteBridgePort, 45123)
    XCTAssertEqual(processManager.controlTunnelRequests.first?.remotePort, 45123)
    XCTAssertEqual(processManager.browserShimInstallRequests.first?.remoteBridgePort, 45123)
  }

  func testPreferredRemoteAgentPortAppliesToSshConfigHost() throws {
    let configURL = try writeTempConfig("""
    Host devbox
      HostName dev.example.test
    """)
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: configURL)

    controller.launchMenuBarApp()
    try controller.setPreferredRemoteAgentPort(45234)
    try controller.startSshConfigHost(alias: "devbox")
    defer { controller.disconnect() }

    let snapshot = controller.snapshot()
    XCTAssertEqual(controller.preferredRemoteAgentPort, 45234)
    XCTAssertEqual(snapshot.activeSession?.remoteBridgePort, 45234)
    XCTAssertEqual(processManager.controlTunnelRequests.first?.remotePort, 45234)
    XCTAssertEqual(processManager.browserShimInstallRequests.first?.remoteBridgePort, 45234)
  }

  func testRejectsInvalidRemoteAgentPortBeforeStartingSession() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())

    controller.launchMenuBarApp()

    XCTAssertThrowsError(try controller.setPreferredRemoteAgentPort(80)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Invalid TCP port: 80"))
    }
    XCTAssertThrowsError(try controller.startSession(destination: "devbox", remoteAgentPort: 80)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Invalid TCP port: 80"))
    }

    let snapshot = controller.snapshot()
    XCTAssertNil(snapshot.activeSession)
    XCTAssertTrue(processManager.controlTunnelRequests.isEmpty)
    XCTAssertTrue(processManager.browserShimInstallRequests.isEmpty)
  }

  func testBrowserOpenCreatesCallbackTunnelBeforeOpen() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())
    var openedURL: URL?
    controller.onOpenURL = { url in
      openedURL = url
      return true
    }

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let url = "https://login.example.test/start?redirect_uri=http%3A%2F%2Flocalhost%3A4999%2Fcallback"
    _ = try controller.processBrowserOpen(urlString: url)

    let snapshot = controller.snapshot()
    XCTAssertEqual(openedURL?.absoluteString, url)
    XCTAssertEqual(processManager.callbackTunnelRequests, [4999])
    XCTAssertTrue(snapshot.tunnels.contains { $0.purpose == .callbackBridge && $0.localPort == 4999 })
    XCTAssertEqual(snapshot.browserRequests.last?.status, .opened)
  }

  func testBrowserOpenQueuesPendingApprovalUntilApproved() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())
    controller.requiresBrowserOpenApproval = true
    var openedURL: URL?
    controller.onOpenURL = { url in
      openedURL = url
      return true
    }

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let url = "https://login.example.test/start?redirect_uri=http%3A%2F%2Flocalhost%3A4999%2Fcallback"
    let queuedRequest = try controller.processBrowserOpen(urlString: url)

    var snapshot = controller.snapshot()
    XCTAssertEqual(queuedRequest.status, .pendingApproval)
    XCTAssertEqual(snapshot.browserRequests.last?.status, .pendingApproval)
    XCTAssertNil(openedURL)
    XCTAssertTrue(processManager.callbackTunnelRequests.isEmpty)
    XCTAssertFalse(snapshot.tunnels.contains { $0.purpose == .callbackBridge })

    let approvedURL = try controller.approveBrowserOpenRequest(id: queuedRequest.id)

    snapshot = controller.snapshot()
    XCTAssertEqual(approvedURL.absoluteString, url)
    XCTAssertEqual(openedURL?.absoluteString, url)
    XCTAssertEqual(processManager.callbackTunnelRequests, [4999])
    XCTAssertTrue(snapshot.tunnels.contains { $0.purpose == .callbackBridge && $0.localPort == 4999 })
    XCTAssertEqual(snapshot.browserRequests.last?.status, .opened)
  }

  func testBrowserOpenPendingApprovalCanBeRejected() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())
    controller.requiresBrowserOpenApproval = true
    controller.onOpenURL = { _ in
      XCTFail("Rejected browser-open requests must not launch the browser.")
      return true
    }

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let url = "https://login.example.test/start?redirect_uri=http%3A%2F%2Flocalhost%3A4999%2Fcallback"
    let queuedRequest = try controller.processBrowserOpen(urlString: url)

    try controller.rejectBrowserOpenRequest(id: queuedRequest.id, reason: "Denied in test.")

    let snapshot = controller.snapshot()
    XCTAssertTrue(processManager.callbackTunnelRequests.isEmpty)
    XCTAssertEqual(snapshot.browserRequests.last?.status, .rejected)
    XCTAssertEqual(snapshot.browserRequests.last?.rejectedReason, "Denied in test.")
  }

  func testHTTPBrowserOpenReturnsQueuedWhenApprovalIsRequired() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())
    controller.requiresBrowserOpenApproval = true

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let url = "https://login.example.test/start?redirect_uri=http%3A%2F%2Flocalhost%3A4999%2Fcallback"
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=?")
    let encodedURL = try XCTUnwrap(url.addingPercentEncoding(withAllowedCharacters: allowed))
    let response = controller.handleHTTPRoute("/open?url=\(encodedURL)")

    let snapshot = controller.snapshot()
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.body, "Queued for approval.")
    XCTAssertEqual(snapshot.browserRequests.last?.status, .pendingApproval)
    XCTAssertTrue(processManager.callbackTunnelRequests.isEmpty)
  }

  func testBrowserOpenHookDenialRejectsBeforeCallbackTunnelAndOpen() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())
    controller.setBrowserOpenHooks([
      BrowserOpenHook(name: "Deny Test Hook") { context in
        XCTAssertEqual(context.targetName, "devbox")
        XCTAssertEqual(context.callbackPort, 4999)
        return .deny("Denied by test hook.")
      }
    ])
    controller.onOpenURL = { _ in
      XCTFail("Denied browser-open requests must not launch the browser.")
      return true
    }

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let url = "https://login.example.test/start?redirect_uri=http%3A%2F%2Flocalhost%3A4999%2Fcallback"
    XCTAssertThrowsError(try controller.processBrowserOpen(urlString: url)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Denied by test hook."))
    }

    let snapshot = controller.snapshot()
    XCTAssertTrue(processManager.callbackTunnelRequests.isEmpty)
    XCTAssertEqual(snapshot.browserRequests.last?.status, .rejected)
    XCTAssertEqual(snapshot.browserRequests.last?.rejectedReason, "Denied by test hook.")
  }

  func testBridgeTestEndpointReturnsStatusWithoutBrowserSideEffects() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let response = controller.handleHTTPRoute("/test")
    let snapshot = controller.snapshot()

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertTrue(response.body.contains("ssh-back test ok"))
    XCTAssertTrue(response.body.contains("target=devbox"))
    XCTAssertTrue(response.body.contains("remote_bridge=127.0.0.1:\(processManager.controlTunnelRequests[0].remotePort)"))
    XCTAssertTrue(snapshot.browserRequests.isEmpty)
    XCTAssertFalse(snapshot.tunnels.contains { $0.purpose == .callbackBridge })
    XCTAssertTrue(processManager.callbackTunnelRequests.isEmpty)
  }

  func testCopyBridgeTestCommandUsesRemoteBridgePort() throws {
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: missingTempConfigURL())

    controller.launchMenuBarApp()
    try controller.startSession(destination: "devbox")
    defer { controller.disconnect() }

    let command = try controller.copyBridgeTestCommand()

    XCTAssertEqual(command, "curl -fsS http://127.0.0.1:\(processManager.controlTunnelRequests[0].remotePort)/test")
  }

  func testLoadsSshConfigHostsAndConnectsByAlias() throws {
    let configURL = try writeTempConfig("""
    Host devbox
      HostName dev.example.test
      User deploy

    Host internal-*
      User deploy
    """)
    let processManager = FakeProcessManager()
    let controller = SSHBackController(processManager: processManager, sshConfigPath: configURL)

    controller.launchMenuBarApp()
    let initialSnapshot = controller.snapshot()
    XCTAssertEqual(initialSnapshot.sshConfigHosts.first(where: { $0.alias == "devbox" })?.connectable, true)
    XCTAssertEqual(initialSnapshot.sshConfigHosts.first(where: { $0.alias == "internal-*" })?.connectable, false)

    try controller.startSshConfigHost(alias: "devbox")
    defer { controller.disconnect() }

    let connectedSnapshot = controller.snapshot()
    XCTAssertEqual(connectedSnapshot.menuBar.status, .connected)
    XCTAssertEqual(connectedSnapshot.activeSession?.targetName, "devbox")
    XCTAssertEqual(processManager.controlTunnelRequests.first?.destination, "devbox")
    XCTAssertEqual(processManager.browserShimInstallRequests.first?.destination, "devbox")
  }
}

private func missingTempConfigURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("config")
}

private func writeTempConfig(_ contents: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("config")
  try contents.write(to: url, atomically: true, encoding: .utf8)
  return url
}

private final class FakeProcessManager: SSHProcessManaging {
  var controlTunnelRequests: [(destination: String, remotePort: Int, localPort: Int)] = []
  var callbackTunnelRequests: [Int] = []
  var browserShimInstallRequests: [(destination: String, remoteBridgePort: Int)] = []
  private var nextProcessIdentifier: Int32 = 1000

  func startControlTunnel(
    destination: String,
    remotePort: Int,
    localPort: Int,
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess {
    controlTunnelRequests.append((destination: destination, remotePort: remotePort, localPort: localPort))
    return nextProcess()
  }

  func startCallbackTunnel(
    destination: String,
    port: Int,
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess {
    callbackTunnelRequests.append(port)
    return nextProcess()
  }

  func installBrowserShim(destination: String, remoteBridgePort: Int) throws -> BrowserShimInstall {
    browserShimInstallRequests.append((destination: destination, remoteBridgePort: remoteBridgePort))
    return BrowserShimInstall(
      browserShimPath: try BrowserShimCommand.remoteShimPath(remoteBridgePort: remoteBridgePort),
      browserEnvShell: "zsh",
      browserEnvRcPath: "~/.zshrc"
    )
  }

  func terminate(processId: String) {}

  func terminateAll() {}

  private func nextProcess() -> ManagedProcess {
    nextProcessIdentifier += 1
    return ManagedProcess(id: UUID().uuidString, processIdentifier: nextProcessIdentifier)
  }
}
