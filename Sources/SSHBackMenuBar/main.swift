import AppKit
import SSHBackCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = SSHBackController()
  private var statusItem: NSStatusItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    controller.onOpenURL = { url in
      DispatchQueue.main.async {
        NSWorkspace.shared.open(url)
      }
      return true
    }

    controller.setBrowserOpenHooks([
      BrowserOpenHook(
        name: "Confirm Browser Open",
        kind: .confirmBrowserOpen
      ) { [weak self] context in
        guard let self else {
          return .deny("ssh-back is not available to confirm the browser request.")
        }

        return self.confirmBrowserOpen(context)
      }
    ])

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

    if let session = snapshot.activeSession, session.status == .ready {
      menu.addItem(.separator())
      let targetItem = NSMenuItem(title: "Target: \(session.targetName)", action: nil, keyEquivalent: "")
      targetItem.isEnabled = false
      menu.addItem(targetItem)

      if let remoteBridgePort = session.remoteBridgePort {
        let bridgeItem = NSMenuItem(title: "Remote bridge: 127.0.0.1:\(remoteBridgePort)", action: nil, keyEquivalent: "")
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

  private func confirmBrowserOpen(_ context: BrowserOpenHookContext) -> BrowserOpenHookDecision {
    if Thread.isMainThread {
      return runBrowserOpenConfirmation(context)
    }

    var decision = BrowserOpenHookDecision.deny("Browser open request was not confirmed.")
    DispatchQueue.main.sync {
      decision = runBrowserOpenConfirmation(context)
    }
    return decision
  }

  private func runBrowserOpenConfirmation(_ context: BrowserOpenHookContext) -> BrowserOpenHookDecision {
    let alert = NSAlert()
    alert.messageText = "Open Browser Login?"
    alert.informativeText = """
    \(context.targetName) wants to open:

    \(context.url)

    Callback: \(context.callbackHost):\(context.callbackPort)
    """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      return .allow
    }

    return .deny("Browser open request was cancelled by the user.")
  }

  private func updateStatusItemAppearance(for snapshot: SSHBackSnapshot) {
    guard let button = statusItem?.button else {
      return
    }

    button.title = ""
    button.imagePosition = .imageOnly
    let accessibilityDescription: String

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
