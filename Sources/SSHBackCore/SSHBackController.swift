import Foundation

public final class SSHBackController {
  private let processManager: SSHProcessManaging
  private let sshConfigPath: URL
  private let lock = NSRecursiveLock()

  private var bridgeServer: BridgeHTTPServer?
  private var menuBar = MenuBarAppState.notRunning
  private var sshConfigHosts: [SshConfigHost] = []
  private var activeSession: SshSession?
  private var tunnelsById: [String: Tunnel] = [:]
  private var browserRequestsById: [String: BrowserOpenRequest] = [:]
  private var browserOpenHooks: [BrowserOpenHook] = []

  public var onStateChange: (() -> Void)?
  public var onOpenURL: ((URL) -> Bool)?

  public init(
    processManager: SSHProcessManaging = SSHProcessManager(),
    sshConfigPath: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
  ) {
    self.processManager = processManager
    self.sshConfigPath = sshConfigPath
  }

  public func launchMenuBarApp() {
    lock.lock()
    menuBar.status = .idle
    menuBar.visibleStatusItem = true
    menuBar.activeSessionId = nil
    menuBar.lastUserMessage = "Ready."
    menuBar.launchedAt = Date()
    lock.unlock()
    _ = loadSshConfigHosts()
  }

  public func snapshot() -> SSHBackSnapshot {
    lock.lock()
    defer { lock.unlock() }

    return SSHBackSnapshot(
      menuBar: menuBar,
      sshConfigHosts: sshConfigHosts,
      activeSession: activeSession,
      tunnels: tunnelsById.values.sorted { $0.id < $1.id },
      browserRequests: browserRequestsById.values.sorted { $0.receivedAt < $1.receivedAt }
    )
  }

  public func setBrowserOpenHooks(_ hooks: [BrowserOpenHook]) {
    lock.lock()
    browserOpenHooks = hooks
    lock.unlock()
  }

  public func addBrowserOpenHook(_ hook: BrowserOpenHook) {
    lock.lock()
    browserOpenHooks.append(hook)
    lock.unlock()
  }

  @discardableResult
  public func loadSshConfigHosts() -> [SshConfigHost] {
    let displayPath = displayPath(for: sshConfigPath)
    let hosts: [SshConfigHost]
    let message: String

    if !FileManager.default.fileExists(atPath: sshConfigPath.path) {
      hosts = []
      message = "No ~/.ssh/config found."
    } else {
      do {
        let contents = try String(contentsOf: sshConfigPath, encoding: .utf8)
        hosts = SSHConfigParser.parse(contents: contents, sourcePath: displayPath)
        let connectableCount = hosts.filter(\.connectable).count
        message = connectableCount == 0
          ? "No concrete SSH config hosts found."
          : "Loaded \(connectableCount) SSH config host\(connectableCount == 1 ? "" : "s")."
      } catch {
        hosts = []
        message = "Could not read \(displayPath): \(error.localizedDescription)"
      }
    }

    lock.lock()
    sshConfigHosts = hosts
    menuBar.lastUserMessage = message
    lock.unlock()
    emitChange()
    return hosts
  }

  public func startSession(destination rawDestination: String) throws {
    let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      throw SSHBackError.emptyDestination
    }

    lock.lock()
    if let session = activeSession, session.status == .ready || session.status == .starting || session.status == .controlReady {
      lock.unlock()
      throw SSHBackError.activeSessionExists
    }

    menuBar.status = .connecting
    menuBar.selectedTargetName = destination
    menuBar.lastUserMessage = "Starting SSH bridge for \(destination)..."
    lock.unlock()
    emitChange()

    let server = BridgeHTTPServer { [weak self] route in
      self?.handleHTTPRoute(route) ?? .serverError("ssh-back is not available.")
    }
    let localBridgePort = Int(try server.start())
    let remoteBridgePort = randomRemoteBridgePort()
    let sessionId = UUID().uuidString
    let controlTunnelId = UUID().uuidString

    let managedProcess = try processManager.startControlTunnel(
      destination: destination,
      remotePort: remoteBridgePort,
      localPort: localBridgePort
    ) { [weak self] status, stderr in
      self?.handleTunnelExit(tunnelId: controlTunnelId, processStatus: status, stderr: stderr)
    }

    let browserShimInstall: BrowserShimInstall
    do {
      browserShimInstall = try processManager.installBrowserShim(
        destination: destination,
        remoteBridgePort: remoteBridgePort
      )
    } catch {
      server.stop()
      processManager.terminate(processId: managedProcess.id)
      throw error
    }

    let now = Date()
    let controlTunnel = Tunnel(
      id: controlTunnelId,
      sessionId: sessionId,
      direction: .remoteToLocal,
      purpose: .controlBridge,
      localHost: "127.0.0.1",
      localPort: localBridgePort,
      remoteHost: "127.0.0.1",
      remotePort: remoteBridgePort,
      status: .open,
      processId: managedProcess.processIdentifier,
      openedAt: now,
      closedAt: nil,
      lastError: nil
    )
    let session = SshSession(
      id: sessionId,
      targetName: destination,
      status: .ready,
      localBridgePort: localBridgePort,
      remoteBridgePort: remoteBridgePort,
      controlTunnelId: controlTunnelId,
      browserShimState: .active,
      browserShimPath: browserShimInstall.browserShimPath,
      browserShimInstalledAt: now,
      browserEnvShell: browserShimInstall.browserEnvShell,
      browserEnvRcPath: browserShimInstall.browserEnvRcPath,
      startedAt: now,
      endedAt: nil,
      lastError: nil
    )

    lock.lock()
    bridgeServer = server
    activeSession = session
    tunnelsById[controlTunnelId] = controlTunnel
    menuBar.status = .connected
    menuBar.activeSessionId = sessionId
    menuBar.lastUserMessage = "Connected. Remote Browser bridge: 127.0.0.1:\(remoteBridgePort)"
    lock.unlock()
    emitChange()
  }

  public func startSshConfigHost(alias: String) throws {
    lock.lock()
    guard let host = sshConfigHosts.first(where: { $0.alias == alias }) else {
      lock.unlock()
      throw SSHBackError.sshConfigHostNotFound(alias)
    }

    guard host.connectable else {
      lock.unlock()
      throw SSHBackError.sshConfigHostNotConnectable(alias)
    }
    lock.unlock()

    try startSession(destination: host.alias)
  }

  public func disconnect() {
    lock.lock()
    let now = Date()
    var session = activeSession
    session?.status = .closed
    session?.endedAt = now
    session?.browserShimState = .notInjected
    session?.browserShimPath = nil
    session?.browserEnvShell = nil
    session?.browserEnvRcPath = nil
    activeSession = session

    for id in tunnelsById.keys {
      tunnelsById[id]?.status = .closed
      tunnelsById[id]?.closedAt = now
    }

    bridgeServer?.stop()
    bridgeServer = nil
    menuBar.status = .idle
    menuBar.activeSessionId = nil
    menuBar.lastUserMessage = "Disconnected."
    lock.unlock()

    processManager.terminateAll()
    emitChange()
  }

  public func reportError(_ message: String) {
    lock.lock()
    menuBar.status = .error
    menuBar.lastUserMessage = message
    lock.unlock()
    emitChange()
  }

  public func copyBrowserShimCommand() throws -> String {
    lock.lock()
    defer { lock.unlock() }

    guard
      let session = activeSession,
      session.status == .ready,
      menuBar.activeSessionId == session.id,
      let remoteBridgePort = session.remoteBridgePort,
      session.browserShimPath != nil
    else {
      throw SSHBackError.noActiveSession
    }

    let command = try BrowserShimCommand.exportCommand(remoteBridgePort: remoteBridgePort)
    menuBar.lastUserMessage = "Copied Browser shim command."
    emitChange()
    return command
  }

  public func copyBridgeTestCommand() throws -> String {
    lock.lock()
    defer { lock.unlock() }

    guard
      let session = activeSession,
      session.status == .ready,
      menuBar.activeSessionId == session.id,
      let remoteBridgePort = session.remoteBridgePort
    else {
      throw SSHBackError.noActiveSession
    }

    let command = "curl -fsS http://127.0.0.1:\(remoteBridgePort)/test"
    menuBar.lastUserMessage = "Copied bridge test command."
    emitChange()
    return command
  }

  public func processBrowserOpen(urlString: String) throws -> URL {
    let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let browserURL = URL(string: trimmedURL), browserURL.scheme != nil else {
      throw SSHBackError.invalidBrowserURL(urlString)
    }

    lock.lock()
    guard let session = activeSession, session.status == .ready else {
      lock.unlock()
      throw SSHBackError.sessionNotReady
    }

    let requestId = UUID().uuidString
    var request = BrowserOpenRequest(
      id: requestId,
      sessionId: session.id,
      url: trimmedURL,
      status: .received,
      callbackHost: nil,
      callbackPort: nil,
      callbackTunnelId: nil,
      receivedAt: Date(),
      openedAt: nil,
      rejectedReason: nil
    )
    browserRequestsById[requestId] = request
    lock.unlock()

    guard let endpoint = CallbackParser.parse(from: trimmedURL) else {
      reject(requestId: requestId, reason: SSHBackError.unsupportedCallback(trimmedURL).localizedDescription)
      throw SSHBackError.unsupportedCallback(trimmedURL)
    }

    request.status = .parsed
    request.callbackHost = endpoint.host
    request.callbackPort = endpoint.port
    lock.lock()
    browserRequestsById[requestId] = request
    lock.unlock()
    emitChange()

    let hookContext = BrowserOpenHookContext(
      sessionId: session.id,
      targetName: session.targetName,
      url: trimmedURL,
      callbackHost: endpoint.host,
      callbackPort: endpoint.port
    )
    try evaluateBrowserOpenHooks(hookContext, requestId: requestId)

    let tunnel = try ensureCallbackTunnel(session: session, port: endpoint.port)
    request.status = .tunneled
    request.callbackTunnelId = tunnel.id

    let didOpen = onOpenURL?(browserURL) ?? false
    if didOpen {
      request.status = .opened
      request.openedAt = Date()
      menuBar.lastUserMessage = "Opened browser URL through callback port \(endpoint.port)."
    } else {
      request.status = .failed
      request.rejectedReason = "The local browser did not accept the URL."
      menuBar.status = .error
      menuBar.lastUserMessage = request.rejectedReason
    }

    lock.lock()
    browserRequestsById[requestId] = request
    lock.unlock()
    emitChange()
    return browserURL
  }

  public func handleHTTPRoute(_ route: String) -> BridgeHTTPResponse {
    guard let components = URLComponents(string: "http://127.0.0.1\(route)") else {
      return .badRequest("Invalid route.")
    }

    if components.path == "/healthz" {
      return .ok("ok")
    }

    if components.path == "/test" {
      do {
        let status = try bridgeTestStatus()
        emitChange()
        return .ok(status)
      } catch {
        return .badRequest(error.localizedDescription)
      }
    }

    guard components.path == "/open" else {
      return .notFound("Unknown route.")
    }

    guard let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value else {
      return .badRequest("Missing url query parameter.")
    }

    do {
      _ = try processBrowserOpen(urlString: urlString)
      return .ok("Opened.")
    } catch {
      return .badRequest(error.localizedDescription)
    }
  }

  private func bridgeTestStatus() throws -> String {
    lock.lock()
    defer { lock.unlock() }

    guard
      let session = activeSession,
      session.status == .ready,
      menuBar.activeSessionId == session.id,
      let localBridgePort = session.localBridgePort,
      let remoteBridgePort = session.remoteBridgePort,
      let controlTunnelId = session.controlTunnelId
    else {
      throw SSHBackError.noActiveSession
    }

    menuBar.lastUserMessage = "Bridge test endpoint reached."

    return """
    ssh-back test ok
    target=\(session.targetName)
    session=\(session.id)
    control_tunnel=\(controlTunnelId)
    local_bridge=127.0.0.1:\(localBridgePort)
    remote_bridge=127.0.0.1:\(remoteBridgePort)
    browser_shim=\(session.browserShimPath ?? "not-installed")
    """
  }

  private func ensureCallbackTunnel(session: SshSession, port: Int) throws -> Tunnel {
    lock.lock()
    if let existing = tunnelsById.values.first(where: {
      $0.sessionId == session.id
        && $0.purpose == .callbackBridge
        && $0.localPort == port
        && $0.status == .open
    }) {
      lock.unlock()
      return existing
    }
    lock.unlock()

    let tunnelId = UUID().uuidString
    let managedProcess = try processManager.startCallbackTunnel(
      destination: session.targetName,
      port: port
    ) { [weak self] status, stderr in
      self?.handleTunnelExit(tunnelId: tunnelId, processStatus: status, stderr: stderr)
    }

    let tunnel = Tunnel(
      id: tunnelId,
      sessionId: session.id,
      direction: .localToRemote,
      purpose: .callbackBridge,
      localHost: "127.0.0.1",
      localPort: port,
      remoteHost: "127.0.0.1",
      remotePort: port,
      status: .open,
      processId: managedProcess.processIdentifier,
      openedAt: Date(),
      closedAt: nil,
      lastError: nil
    )

    lock.lock()
    tunnelsById[tunnelId] = tunnel
    lock.unlock()
    emitChange()
    return tunnel
  }

  private func reject(requestId: String, reason: String) {
    lock.lock()
    browserRequestsById[requestId]?.status = .rejected
    browserRequestsById[requestId]?.rejectedReason = reason
    menuBar.lastUserMessage = reason
    lock.unlock()
    emitChange()
  }

  private func evaluateBrowserOpenHooks(
    _ context: BrowserOpenHookContext,
    requestId: String
  ) throws {
    lock.lock()
    let hooks = browserOpenHooks
    lock.unlock()

    for hook in hooks where hook.enabled {
      switch hook.evaluate(context) {
      case .allow:
        continue
      case .deny(let reason):
        let message = reason.isEmpty
          ? "Browser open request was rejected by \(hook.name)."
          : reason
        reject(requestId: requestId, reason: message)
        throw SSHBackError.browserOpenRejected(message)
      }
    }
  }

  private func handleTunnelExit(tunnelId: String, processStatus: Int32, stderr: String) {
    lock.lock()
    let now = Date()
    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let purpose = tunnelsById[tunnelId]?.purpose

    if let currentStatus = tunnelsById[tunnelId]?.status, currentStatus == .open || currentStatus == .opening {
      tunnelsById[tunnelId]?.status = processStatus == 0 ? .closed : .failed
      tunnelsById[tunnelId]?.closedAt = now
      tunnelsById[tunnelId]?.lastError = processStatus == 0 ? nil : message
    }

    if purpose == .controlBridge, activeSession?.status == .ready {
      activeSession?.status = processStatus == 0 ? .closed : .failed
      activeSession?.endedAt = now
      activeSession?.lastError = processStatus == 0 ? nil : message
      menuBar.status = processStatus == 0 ? .idle : .error
      menuBar.activeSessionId = nil
      menuBar.lastUserMessage = processStatus == 0 ? "Disconnected." : (message.isEmpty ? "SSH control tunnel failed." : message)
      bridgeServer?.stop()
      bridgeServer = nil
    }

    lock.unlock()
    emitChange()
  }

  private func randomRemoteBridgePort() -> Int {
    Int.random(in: 41000...60999)
  }

  private func displayPath(for url: URL) -> String {
    let path = url.path
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "\(homePath)/.ssh/config" {
      return "~/.ssh/config"
    }
    return path
  }

  private func emitChange() {
    DispatchQueue.main.async { [weak self] in
      self?.onStateChange?()
    }
  }
}
