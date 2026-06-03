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
  private var browserOpenRequiresApproval = false
  private var configuredRemoteAgentPort: Int?

  public var onStateChange: (() -> Void)?
  public var onOpenURL: ((URL) -> Bool)?
  public var preferredRemoteAgentPort: Int? {
    lock.lock()
    defer { lock.unlock() }
    return configuredRemoteAgentPort
  }
  public var requiresBrowserOpenApproval: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return browserOpenRequiresApproval
    }
    set {
      lock.lock()
      browserOpenRequiresApproval = newValue
      lock.unlock()
    }
  }

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

  public func setPreferredRemoteAgentPort(_ port: Int?) throws {
    if let port, !CallbackParser.isSupportedCallbackPort(port) {
      throw SSHBackError.invalidPort(port)
    }

    lock.lock()
    configuredRemoteAgentPort = port
    if let port {
      menuBar.lastUserMessage = "Remote Agent port set to \(port)."
    } else {
      menuBar.lastUserMessage = "Remote Agent port set to automatic."
    }
    lock.unlock()
    emitChange()
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

  public func startSession(destination rawDestination: String, remoteAgentPort requestedRemoteAgentPort: Int? = nil) throws {
    let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      throw SSHBackError.emptyDestination
    }

    let remoteBridgePort = try resolveRemoteAgentPort(requestedRemoteAgentPort)

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

  public func startSshConfigHost(alias: String, remoteAgentPort requestedRemoteAgentPort: Int? = nil) throws {
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

    try startSession(destination: host.alias, remoteAgentPort: requestedRemoteAgentPort)
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

    for id in browserRequestsById.keys where browserRequestsById[id]?.status == .pendingApproval {
      browserRequestsById[id]?.status = .rejected
      browserRequestsById[id]?.rejectedReason = "Disconnected before approval."
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

  @discardableResult
  public func processBrowserOpen(urlString: String) throws -> BrowserOpenRequest {
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
      targetName: session.targetName,
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

    lock.lock()
    let requiresApproval = browserOpenRequiresApproval
    lock.unlock()

    if requiresApproval {
      request.status = .pendingApproval
      lock.lock()
      browserRequestsById[requestId] = request
      menuBar.lastUserMessage = "Browser open request is waiting for approval."
      lock.unlock()
      emitChange()
      return request
    }

    return try openBrowserRequest(
      requestId: requestId,
      session: session,
      browserURL: browserURL,
      callbackPort: endpoint.port
    )
  }

  @discardableResult
  public func approveBrowserOpenRequest(id requestId: String) throws -> URL {
    lock.lock()
    guard let request = browserRequestsById[requestId] else {
      lock.unlock()
      throw SSHBackError.browserOpenRequestNotFound(requestId)
    }

    guard request.status == .pendingApproval else {
      lock.unlock()
      throw SSHBackError.browserOpenRequestNotPending(requestId)
    }

    guard
      let session = activeSession,
      session.status == .ready,
      session.id == request.sessionId,
      let callbackPort = request.callbackPort
    else {
      lock.unlock()
      throw SSHBackError.sessionNotReady
    }

    browserRequestsById[requestId]?.status = .approving
    menuBar.lastUserMessage = "Approving browser open request..."
    lock.unlock()
    emitChange()

    guard let browserURL = URL(string: request.url), browserURL.scheme != nil else {
      throw SSHBackError.invalidBrowserURL(request.url)
    }

    _ = try openBrowserRequest(
      requestId: requestId,
      session: session,
      browserURL: browserURL,
      callbackPort: callbackPort
    )
    return browserURL
  }

  public func rejectBrowserOpenRequest(id requestId: String, reason: String = "Browser open request was denied by the user.") throws {
    lock.lock()
    guard let request = browserRequestsById[requestId] else {
      lock.unlock()
      throw SSHBackError.browserOpenRequestNotFound(requestId)
    }

    guard request.status == .pendingApproval else {
      lock.unlock()
      throw SSHBackError.browserOpenRequestNotPending(requestId)
    }

    browserRequestsById[request.id]?.status = .rejected
    browserRequestsById[request.id]?.rejectedReason = reason
    menuBar.lastUserMessage = reason
    lock.unlock()
    emitChange()
  }

  private func openBrowserRequest(
    requestId: String,
    session: SshSession,
    browserURL: URL,
    callbackPort: Int
  ) throws -> BrowserOpenRequest {
    let tunnel: Tunnel
    do {
      tunnel = try ensureCallbackTunnel(session: session, port: callbackPort)
    } catch {
      fail(requestId: requestId, reason: error.localizedDescription)
      throw error
    }

    lock.lock()
    var request = browserRequestsById[requestId]
    request?.status = .tunneled
    request?.callbackTunnelId = tunnel.id
    if let request {
      browserRequestsById[requestId] = request
    }
    lock.unlock()
    emitChange()

    let didOpen = onOpenURL?(browserURL) ?? false
    lock.lock()
    request = browserRequestsById[requestId]
    if didOpen {
      request?.status = .opened
      request?.openedAt = Date()
      menuBar.lastUserMessage = "Opened browser URL through callback port \(callbackPort)."
    } else {
      request?.status = .failed
      request?.rejectedReason = "The local browser did not accept the URL."
      menuBar.status = .error
      menuBar.lastUserMessage = request?.rejectedReason
    }

    if let request {
      browserRequestsById[requestId] = request
    }
    lock.unlock()
    emitChange()
    return request ?? BrowserOpenRequest(
      id: requestId,
      sessionId: session.id,
      targetName: session.targetName,
      url: browserURL.absoluteString,
      status: didOpen ? .opened : .failed,
      callbackHost: nil,
      callbackPort: callbackPort,
      callbackTunnelId: tunnel.id,
      receivedAt: Date(),
      openedAt: didOpen ? Date() : nil,
      rejectedReason: didOpen ? nil : "The local browser did not accept the URL."
    )
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
      let request = try processBrowserOpen(urlString: urlString)
      switch request.status {
      case .pendingApproval:
        return .ok("Queued for approval.")
      case .opened:
        return .ok("Opened.")
      case .failed:
        return .badRequest(request.rejectedReason ?? "Failed to open browser URL.")
      default:
        return .ok("Received.")
      }
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

  private func fail(requestId: String, reason: String) {
    lock.lock()
    browserRequestsById[requestId]?.status = .failed
    browserRequestsById[requestId]?.rejectedReason = reason
    menuBar.status = .error
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

  private func resolveRemoteAgentPort(_ requestedRemoteAgentPort: Int?) throws -> Int {
    lock.lock()
    let configuredPort = configuredRemoteAgentPort
    lock.unlock()

    let port = requestedRemoteAgentPort ?? configuredPort ?? randomRemoteBridgePort()
    guard CallbackParser.isSupportedCallbackPort(port) else {
      throw SSHBackError.invalidPort(port)
    }
    return port
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
