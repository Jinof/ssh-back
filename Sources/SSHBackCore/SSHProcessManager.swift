import Foundation

public struct ManagedProcess: Equatable {
  public var id: String
  public var processIdentifier: Int32
}

public protocol SSHProcessManaging: AnyObject {
  func startControlTunnel(
    destination: String,
    remotePort: Int,
    localPort: Int,
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess

  func startCallbackTunnel(
    destination: String,
    port: Int,
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess

  func installBrowserShim(
    destination: String,
    remoteBridgePort: Int
  ) throws -> BrowserShimInstall

  func terminate(processId: String)
  func terminateAll()
}

public final class SSHProcessManager: SSHProcessManaging {
  private let lock = NSLock()
  private var processes: [String: Process] = [:]

  public init() {}

  public func startControlTunnel(
    destination: String,
    remotePort: Int,
    localPort: Int,
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess {
    try validatePort(remotePort)
    try validatePort(localPort)

    return try startSSH(
      destination: destination,
      forwardingArguments: [
        "-R",
        "\(remotePort):127.0.0.1:\(localPort)"
      ],
      onExit: onExit
    )
  }

  public func startCallbackTunnel(
    destination: String,
    port: Int,
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess {
    try validatePort(port)

    return try startSSH(
      destination: destination,
      forwardingArguments: [
        "-L",
        "\(port):127.0.0.1:\(port)"
      ],
      onExit: onExit
    )
  }

  public func installBrowserShim(
    destination: String,
    remoteBridgePort: Int
  ) throws -> BrowserShimInstall {
    try validatePort(remoteBridgePort)

    let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDestination.isEmpty else {
      throw SSHBackError.emptyDestination
    }

    let remotePath = try BrowserShimCommand.remoteShimPath(remoteBridgePort: remoteBridgePort)
    let installScript = try BrowserShimCommand.installScript(remoteBridgePort: remoteBridgePort)

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=10",
      trimmedDestination,
      "/bin/sh", "-s"
    ]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
      stdinPipe.fileHandleForWriting.write(Data(installScript.utf8))
      try stdinPipe.fileHandleForWriting.close()
      process.waitUntilExit()
    } catch {
      throw SSHBackError.sshLaunchFailed(error.localizedDescription)
    }

    if process.terminationStatus != 0 {
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stderr = String(data: data, encoding: .utf8) ?? ""
      throw SSHBackError.sshLaunchFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: data, encoding: .utf8) ?? ""
    return try parseBrowserShimInstallOutput(stdout, fallbackPath: remotePath)
  }

  public func terminate(processId: String) {
    lock.lock()
    let process = processes.removeValue(forKey: processId)
    lock.unlock()

    process?.terminate()
  }

  public func terminateAll() {
    lock.lock()
    let activeProcesses = processes
    processes.removeAll()
    lock.unlock()

    for process in activeProcesses.values {
      process.terminate()
    }
  }

  private func startSSH(
    destination: String,
    forwardingArguments: [String],
    onExit: @escaping (Int32, String) -> Void
  ) throws -> ManagedProcess {
    let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDestination.isEmpty else {
      throw SSHBackError.emptyDestination
    }

    let id = UUID().uuidString
    let process = Process()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-N",
      "-T",
      "-o", "ExitOnForwardFailure=yes",
      "-o", "BatchMode=yes",
      "-o", "ServerAliveInterval=30",
      "-o", "ServerAliveCountMax=2"
    ] + forwardingArguments + [trimmedDestination]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = stderrPipe
    process.terminationHandler = { [weak self] terminatedProcess in
      let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stderr = String(data: data, encoding: .utf8) ?? ""

      self?.lock.lock()
      self?.processes.removeValue(forKey: id)
      self?.lock.unlock()

      onExit(terminatedProcess.terminationStatus, stderr)
    }

    do {
      try process.run()
    } catch {
      throw SSHBackError.sshLaunchFailed(error.localizedDescription)
    }

    lock.lock()
    processes[id] = process
    lock.unlock()

    return ManagedProcess(id: id, processIdentifier: process.processIdentifier)
  }

  private func parseBrowserShimInstallOutput(
    _ output: String,
    fallbackPath: String
  ) throws -> BrowserShimInstall {
    var metadata: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      guard let separator = line.firstIndex(of: "=") else {
        continue
      }
      let key = String(line[..<separator])
      let value = String(line[line.index(after: separator)...])
      metadata[key] = value
    }

    guard
      let browserEnvShell = metadata["SSH_BACK_ENV_SHELL"],
      !browserEnvShell.isEmpty,
      let browserEnvRcPath = metadata["SSH_BACK_ENV_RC"],
      !browserEnvRcPath.isEmpty
    else {
      throw SSHBackError.sshLaunchFailed("Browser shim install did not report the remote shell rc file.")
    }

    return BrowserShimInstall(
      browserShimPath: metadata["SSH_BACK_BROWSER_PATH"] ?? fallbackPath,
      browserEnvShell: browserEnvShell,
      browserEnvRcPath: browserEnvRcPath
    )
  }

  private func validatePort(_ port: Int) throws {
    guard CallbackParser.isSupportedCallbackPort(port) else {
      throw SSHBackError.invalidPort(port)
    }
  }
}
