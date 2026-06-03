import AppKit
import SSHBackCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = SSHBackController()
  private let remoteAgentPortDefaultsKey = "RemoteAgentPort"
  private var statusItem: NSStatusItem?
  private lazy var requestTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
  }()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    controller.requiresBrowserOpenApproval = true
    loadPreferredRemoteAgentPort()

    controller.onOpenURL = { url in
      DispatchQueue.main.async {
        NSWorkspace.shared.open(url)
      }
      return true
    }

    controller.onStateChange = { [weak self] in
      self?.rebuildMenu()
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    if let button = item.button {
      button.title = ""
    }

    controller.launchMenuBarApp()
    rebuildMenu()
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller.disconnect()
  }

  private func rebuildMenu() {
    let snapshot = controller.snapshot()
    updateStatusItemAppearance(for: snapshot)

    let menu = NSMenu()

    let title = NSMenuItem(title: "SSH Back", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)

    let status = NSMenuItem(title: statusText(for: snapshot), action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)

    if let message = snapshot.menuBar.lastUserMessage, !message.isEmpty {
      let messageItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
      messageItem.isEnabled = false
      menu.addItem(messageItem)
    }

    let remoteAgentPortItem = NSMenuItem(title: remoteAgentPortMenuTitle(), action: #selector(configureRemoteAgentPort), keyEquivalent: "p")
    remoteAgentPortItem.target = self
    menu.addItem(remoteAgentPortItem)

    if let session = snapshot.activeSession, session.status == .ready {
      menu.addItem(.separator())
      let targetItem = NSMenuItem(title: "Target: \(session.targetName)", action: nil, keyEquivalent: "")
      targetItem.isEnabled = false
      menu.addItem(targetItem)

      if let remoteBridgePort = session.remoteBridgePort {
        let bridgeItem = NSMenuItem(title: "Remote Agent: 127.0.0.1:\(remoteBridgePort)", action: nil, keyEquivalent: "")
        bridgeItem.isEnabled = false
        menu.addItem(bridgeItem)
      }

      if let browserShimPath = session.browserShimPath {
        let shimItem = NSMenuItem(title: "Browser shim: \(browserShimPath)", action: nil, keyEquivalent: "")
        shimItem.isEnabled = false
        menu.addItem(shimItem)
      }

      if let browserEnvRcPath = session.browserEnvRcPath {
        let shellName = session.browserEnvShell.map { " (\($0))" } ?? ""
        let envItem = NSMenuItem(title: "Browser env: \(browserEnvRcPath)\(shellName)", action: nil, keyEquivalent: "")
        envItem.isEnabled = false
        menu.addItem(envItem)
      }
    }

    addBrowserRequestsMenu(to: menu, snapshot: snapshot)
    menu.addItem(.separator())

    let canConnect = snapshot.activeSession == nil || snapshot.menuBar.status == .idle || snapshot.menuBar.status == .error
    let connectItem = NSMenuItem(title: "Connect...", action: #selector(connect), keyEquivalent: "c")
    connectItem.target = self
    connectItem.isEnabled = canConnect
    menu.addItem(connectItem)

    let configHostsItem = NSMenuItem(title: "SSH Config Hosts", action: nil, keyEquivalent: "")
    let configHostsMenu = NSMenu()
    let connectableHosts = snapshot.sshConfigHosts.filter(\.connectable)
    if connectableHosts.isEmpty {
      let emptyItem = NSMenuItem(title: "No concrete hosts found", action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      configHostsMenu.addItem(emptyItem)
    } else {
      for host in connectableHosts {
        let hostItem = NSMenuItem(title: host.displayName, action: #selector(connectSshConfigHost(_:)), keyEquivalent: "")
        hostItem.target = self
        hostItem.representedObject = host.alias
        hostItem.isEnabled = canConnect
        configHostsMenu.addItem(hostItem)
      }
    }
    configHostsMenu.addItem(.separator())
    let refreshItem = NSMenuItem(title: "Refresh SSH Config Hosts", action: #selector(refreshSshConfigHosts), keyEquivalent: "r")
    refreshItem.target = self
    configHostsMenu.addItem(refreshItem)
    configHostsItem.submenu = configHostsMenu
    menu.addItem(configHostsItem)

    let copyItem = NSMenuItem(title: "Copy Browser Shim", action: #selector(copyBrowserShim), keyEquivalent: "b")
    copyItem.target = self
    copyItem.isEnabled = snapshot.activeSession?.status == .ready
    menu.addItem(copyItem)

    let copyTestItem = NSMenuItem(title: "Copy Test Command", action: #selector(copyTestCommand), keyEquivalent: "t")
    copyTestItem.target = self
    copyTestItem.isEnabled = snapshot.activeSession?.status == .ready
    menu.addItem(copyTestItem)

    let testItem = NSMenuItem(title: "Open Test URL...", action: #selector(openTestURL), keyEquivalent: "o")
    testItem.target = self
    testItem.isEnabled = snapshot.activeSession?.status == .ready
    menu.addItem(testItem)

    let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
    disconnectItem.target = self
    disconnectItem.isEnabled = snapshot.activeSession != nil
    menu.addItem(disconnectItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(title: "Quit SSH Back", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem?.menu = menu
  }

  private func statusText(for snapshot: SSHBackSnapshot) -> String {
    switch snapshot.menuBar.status {
    case .notRunning:
      return "Not running"
    case .idle:
      return "Idle"
    case .connecting:
      return "Connecting..."
    case .connected:
      return "Connected"
    case .error:
      return "Error"
    }
  }

  private func loadPreferredRemoteAgentPort() {
    guard UserDefaults.standard.object(forKey: remoteAgentPortDefaultsKey) != nil else {
      return
    }

    let port = UserDefaults.standard.integer(forKey: remoteAgentPortDefaultsKey)
    do {
      try controller.setPreferredRemoteAgentPort(port)
    } catch {
      UserDefaults.standard.removeObject(forKey: remoteAgentPortDefaultsKey)
      controller.reportError("Ignored invalid saved Remote Agent port: \(port)")
    }
  }

  private func remoteAgentPortMenuTitle() -> String {
    if let port = controller.preferredRemoteAgentPort {
      return "Remote Agent Port: \(port)"
    }
    return "Remote Agent Port: Auto"
  }

  @objc private func configureRemoteAgentPort() {
    let alert = NSAlert()
    alert.messageText = "Remote Agent Port"
    alert.informativeText = "Set the remote port used by the browser shim on the SSH target. Changes apply to new SSH sessions. Leave empty or choose Auto to use a random port."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Auto")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "Auto"
    if let port = controller.preferredRemoteAgentPort {
      field.stringValue = "\(port)"
    }
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
      do {
        let port = try parseRemoteAgentPort(field.stringValue)
        try savePreferredRemoteAgentPort(port)
      } catch {
        controller.reportError(error.localizedDescription)
        showError(error)
      }
    case .alertSecondButtonReturn:
      do {
        try savePreferredRemoteAgentPort(nil)
      } catch {
        controller.reportError(error.localizedDescription)
        showError(error)
      }
    default:
      break
    }
  }

  private func parseRemoteAgentPort(_ value: String) throws -> Int? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    guard let port = Int(trimmed), CallbackParser.isSupportedCallbackPort(port) else {
      throw SSHBackError.invalidPort(Int(trimmed) ?? 0)
    }
    return port
  }

  private func savePreferredRemoteAgentPort(_ port: Int?) throws {
    try controller.setPreferredRemoteAgentPort(port)
    if let port {
      UserDefaults.standard.set(port, forKey: remoteAgentPortDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: remoteAgentPortDefaultsKey)
    }
    rebuildMenu()
  }

  private func addBrowserRequestsMenu(to menu: NSMenu, snapshot: SSHBackSnapshot) {
    let pendingRequests = snapshot.browserRequests
      .filter { $0.status == .pendingApproval }
      .sorted { $0.receivedAt < $1.receivedAt }
    let recentRequests = snapshot.browserRequests
      .filter { $0.status != .pendingApproval }
      .sorted { $0.receivedAt > $1.receivedAt }
      .prefix(8)

    guard !pendingRequests.isEmpty || !recentRequests.isEmpty else {
      return
    }

    menu.addItem(.separator())

    let title: String
    if pendingRequests.isEmpty {
      title = "Browser Requests"
    } else {
      title = "Browser Requests (\(pendingRequests.count) pending)"
    }
    let requestsItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let requestsMenu = NSMenu()

    if pendingRequests.isEmpty {
      addDisabledItem("No pending approvals", to: requestsMenu)
    } else {
      addDisabledItem("Pending Approval", to: requestsMenu)
      for request in pendingRequests {
        addBrowserRequestItem(request, pending: true, to: requestsMenu)
      }
    }

    if !recentRequests.isEmpty {
      requestsMenu.addItem(.separator())
      addDisabledItem("Recent", to: requestsMenu)
      for request in recentRequests {
        addBrowserRequestItem(request, pending: false, to: requestsMenu)
      }
    }

    requestsItem.submenu = requestsMenu
    menu.addItem(requestsItem)
  }

  private func addBrowserRequestItem(_ request: BrowserOpenRequest, pending: Bool, to menu: NSMenu) {
    let item = NSMenuItem(title: browserRequestTitle(request), action: nil, keyEquivalent: "")
    let submenu = NSMenu()

    addDisabledItem("Target: \(request.targetName)", to: submenu)
    addDisabledItem("Status: \(browserRequestStatusText(request.status))", to: submenu)
    addDisabledItem("Received: \(requestTimeFormatter.string(from: request.receivedAt))", to: submenu)
    if let callbackHost = request.callbackHost, let callbackPort = request.callbackPort {
      addDisabledItem("Callback: \(callbackHost):\(callbackPort)", to: submenu)
    }
    addDisabledItem("URL: \(shortURL(request.url, maxLength: 96))", to: submenu)
    if let reason = request.rejectedReason, !reason.isEmpty {
      addDisabledItem("Reason: \(shortURL(reason, maxLength: 96))", to: submenu)
    }

    submenu.addItem(.separator())
    if pending {
      let approveItem = NSMenuItem(title: "Approve", action: #selector(approveBrowserRequest(_:)), keyEquivalent: "")
      approveItem.target = self
      approveItem.representedObject = request.id
      submenu.addItem(approveItem)

      let denyItem = NSMenuItem(title: "Deny", action: #selector(denyBrowserRequest(_:)), keyEquivalent: "")
      denyItem.target = self
      denyItem.representedObject = request.id
      submenu.addItem(denyItem)

      submenu.addItem(.separator())
    }

    let copyItem = NSMenuItem(title: "Copy URL", action: #selector(copyBrowserRequestURL(_:)), keyEquivalent: "")
    copyItem.target = self
    copyItem.representedObject = request.id
    submenu.addItem(copyItem)

    item.submenu = submenu
    menu.addItem(item)
  }

  private func addDisabledItem(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }

  private func browserRequestTitle(_ request: BrowserOpenRequest) -> String {
    "\(browserRequestStatusText(request.status)): \(shortURL(request.url, maxLength: 64))"
  }

  private func browserRequestStatusText(_ status: BrowserOpenStatus) -> String {
    switch status {
    case .received:
      return "Received"
    case .parsed:
      return "Parsed"
    case .pendingApproval:
      return "Pending"
    case .approving:
      return "Approving"
    case .tunneled:
      return "Tunneled"
    case .opened:
      return "Opened"
    case .rejected:
      return "Rejected"
    case .failed:
      return "Failed"
    }
  }

  private func shortURL(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else {
      return value
    }

    let endIndex = value.index(value.startIndex, offsetBy: maxLength - 3)
    return "\(value[..<endIndex])..."
  }

  @objc private func connect() {
    let alert = NSAlert()
    alert.messageText = "Connect SSH Target"
    alert.informativeText = "Enter an SSH destination from your ssh config or user@host."
    alert.addButton(withTitle: "Connect")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "devbox or user@example.com"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    let destination = field.stringValue
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        return
      }

      do {
        try self.controller.startSession(destination: destination)
      } catch {
        self.controller.reportError(error.localizedDescription)
        self.showError(error)
      }
    }
  }

  @objc private func connectSshConfigHost(_ sender: NSMenuItem) {
    guard let alias = sender.representedObject as? String else {
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        return
      }

      do {
        try self.controller.startSshConfigHost(alias: alias)
      } catch {
        self.controller.reportError(error.localizedDescription)
        self.showError(error)
      }
    }
  }

  @objc private func refreshSshConfigHosts() {
    _ = controller.loadSshConfigHosts()
    rebuildMenu()
  }

  @objc private func copyBrowserShim() {
    do {
      let command = try controller.copyBrowserShimCommand()
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      rebuildMenu()
    } catch {
      controller.reportError(error.localizedDescription)
      showError(error)
    }
  }

  @objc private func copyTestCommand() {
    do {
      let command = try controller.copyBridgeTestCommand()
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      rebuildMenu()
    } catch {
      controller.reportError(error.localizedDescription)
      showError(error)
    }
  }

  @objc private func openTestURL() {
    let alert = NSAlert()
    alert.messageText = "Open Test URL"
    alert.informativeText = "Paste a login URL that contains a loopback callback port."
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
    field.placeholderString = "https://example.com/login?redirect_uri=http://localhost:3000/callback"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    let testURL = field.stringValue
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        return
      }

      do {
        _ = try self.controller.processBrowserOpen(urlString: testURL)
      } catch {
        self.controller.reportError(error.localizedDescription)
        self.showError(error)
      }
    }
  }

  @objc private func approveBrowserRequest(_ sender: NSMenuItem) {
    guard let requestId = sender.representedObject as? String else {
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        return
      }

      do {
        _ = try self.controller.approveBrowserOpenRequest(id: requestId)
      } catch {
        self.controller.reportError(error.localizedDescription)
        self.showError(error)
      }
    }
  }

  @objc private func denyBrowserRequest(_ sender: NSMenuItem) {
    guard let requestId = sender.representedObject as? String else {
      return
    }

    do {
      try controller.rejectBrowserOpenRequest(id: requestId)
      rebuildMenu()
    } catch {
      controller.reportError(error.localizedDescription)
      showError(error)
    }
  }

  @objc private func copyBrowserRequestURL(_ sender: NSMenuItem) {
    guard
      let requestId = sender.representedObject as? String,
      let request = controller.snapshot().browserRequests.first(where: { $0.id == requestId })
    else {
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(request.url, forType: .string)
  }

  @objc private func disconnect() {
    controller.disconnect()
  }

  @objc private func quit() {
    controller.disconnect()
    NSApp.terminate(nil)
  }

  private func showError(_ error: Error) {
    DispatchQueue.main.async {
      let alert = NSAlert(error: error)
      alert.runModal()
    }
  }

  private func updateStatusItemAppearance(for snapshot: SSHBackSnapshot) {
    guard let button = statusItem?.button else {
      return
    }

    button.title = ""
    button.imagePosition = .imageOnly
    let accessibilityDescription: String

    if snapshot.browserRequests.contains(where: { $0.status == .pendingApproval }) {
      accessibilityDescription = "SSH Back Pending Browser Approval"
      button.image = statusDotImage(color: .systemOrange, accessibilityDescription: accessibilityDescription)
      button.contentTintColor = nil
      button.setAccessibilityLabel(accessibilityDescription)
      return
    }

    switch snapshot.menuBar.status {
    case .connected:
      accessibilityDescription = "SSH Back Connected"
      button.image = statusDotImage(color: .systemGreen, accessibilityDescription: accessibilityDescription)
    case .connecting:
      accessibilityDescription = "SSH Back Connecting"
      button.image = statusDotImage(color: .systemOrange, accessibilityDescription: accessibilityDescription)
    case .error:
      accessibilityDescription = "SSH Back Error"
      button.image = statusDotImage(color: .systemRed, accessibilityDescription: accessibilityDescription)
    case .notRunning, .idle:
      accessibilityDescription = "SSH Back"
      button.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: accessibilityDescription)
      button.image?.isTemplate = true
    }

    button.contentTintColor = nil
    button.setAccessibilityLabel(accessibilityDescription)
  }

  private func statusDotImage(color: NSColor, accessibilityDescription: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()

    let circleRect = NSRect(x: 2, y: 2, width: 8, height: 8)
    NSColor.black.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: circleRect.offsetBy(dx: 0, dy: -0.5)).fill()

    color.setFill()
    NSBezierPath(ovalIn: circleRect).fill()

    image.unlockFocus()
    image.isTemplate = false
    image.accessibilityDescription = accessibilityDescription
    return image
  }
}

private let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
