import Foundation

public enum SessionStatus: String, Equatable {
  case starting
  case controlReady = "control_ready"
  case ready
  case closing
  case closed
  case failed
}

public enum BrowserShimState: String, Equatable {
  case notInjected = "not_injected"
  case injected
  case active
  case failed
}

public enum TunnelDirection: String, Equatable {
  case remoteToLocal = "remote_to_local"
  case localToRemote = "local_to_remote"
}

public enum TunnelPurpose: String, Equatable {
  case controlBridge = "control_bridge"
  case callbackBridge = "callback_bridge"
}

public enum TunnelStatus: String, Equatable {
  case requested
  case opening
  case open
  case closing
  case closed
  case failed
}

public enum BrowserOpenStatus: String, Equatable {
  case received
  case parsed
  case pendingApproval = "pending_approval"
  case approving
  case tunneled
  case opened
  case rejected
  case failed
}

public enum MenuBarStatus: String, Equatable {
  case notRunning = "not_running"
  case idle
  case connecting
  case connected
  case error
}

public struct SshTarget: Equatable {
  public var name: String
  public var sshDestination: String
  public var sshArgs: [String]
  public var defaultRemoteHost: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    name: String,
    sshDestination: String,
    sshArgs: [String] = [],
    defaultRemoteHost: String = "127.0.0.1",
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.name = name
    self.sshDestination = sshDestination
    self.sshArgs = sshArgs
    self.defaultRemoteHost = defaultRemoteHost
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct SshConfigHost: Equatable {
  public var alias: String
  public var sourcePath: String
  public var hostName: String?
  public var user: String?
  public var port: Int?
  public var connectable: Bool
  public var loadedAt: Date

  public init(
    alias: String,
    sourcePath: String,
    hostName: String? = nil,
    user: String? = nil,
    port: Int? = nil,
    connectable: Bool,
    loadedAt: Date = Date()
  ) {
    self.alias = alias
    self.sourcePath = sourcePath
    self.hostName = hostName
    self.user = user
    self.port = port
    self.connectable = connectable
    self.loadedAt = loadedAt
  }

  public var displayName: String {
    var destination = ""
    if let user, !user.isEmpty {
      destination += "\(user)@"
    }
    if let hostName, !hostName.isEmpty {
      destination += hostName
    }
    if let port {
      destination += ":\(port)"
    }

    return destination.isEmpty ? alias : "\(alias) (\(destination))"
  }
}

public struct SshSession: Equatable {
  public var id: String
  public var targetName: String
  public var status: SessionStatus
  public var localBridgePort: Int?
  public var remoteBridgePort: Int?
  public var controlTunnelId: String?
  public var browserShimState: BrowserShimState
  public var browserShimPath: String?
  public var browserShimInstalledAt: Date?
  public var browserEnvShell: String?
  public var browserEnvRcPath: String?
  public var startedAt: Date
  public var endedAt: Date?
  public var lastError: String?
}

public struct BrowserShimInstall: Equatable {
  public var browserShimPath: String
  public var browserEnvShell: String
  public var browserEnvRcPath: String

  public init(
    browserShimPath: String,
    browserEnvShell: String,
    browserEnvRcPath: String
  ) {
    self.browserShimPath = browserShimPath
    self.browserEnvShell = browserEnvShell
    self.browserEnvRcPath = browserEnvRcPath
  }
}

public struct Tunnel: Equatable {
  public var id: String
  public var sessionId: String
  public var direction: TunnelDirection
  public var purpose: TunnelPurpose
  public var localHost: String
  public var localPort: Int
  public var remoteHost: String
  public var remotePort: Int
  public var status: TunnelStatus
  public var processId: Int32?
  public var openedAt: Date?
  public var closedAt: Date?
  public var lastError: String?
}

public struct BrowserOpenRequest: Equatable {
  public var id: String
  public var sessionId: String
  public var targetName: String
  public var url: String
  public var status: BrowserOpenStatus
  public var callbackHost: String?
  public var callbackPort: Int?
  public var callbackTunnelId: String?
  public var receivedAt: Date
  public var openedAt: Date?
  public var rejectedReason: String?
}

public struct MenuBarAppState: Equatable {
  public var status: MenuBarStatus
  public var visibleStatusItem: Bool
  public var activeSessionId: String?
  public var selectedTargetName: String?
  public var lastUserMessage: String?
  public var launchedAt: Date?

  public static let notRunning = MenuBarAppState(
    status: .notRunning,
    visibleStatusItem: false,
    activeSessionId: nil,
    selectedTargetName: nil,
    lastUserMessage: nil,
    launchedAt: nil
  )
}

public struct SSHBackSnapshot: Equatable {
  public var menuBar: MenuBarAppState
  public var sshConfigHosts: [SshConfigHost]
  public var activeSession: SshSession?
  public var tunnels: [Tunnel]
  public var browserRequests: [BrowserOpenRequest]
}

public enum SSHBackError: Error, LocalizedError {
  case emptyDestination
  case activeSessionExists
  case noActiveSession
  case sessionNotReady
  case invalidBrowserURL(String)
  case unsupportedCallback(String)
  case invalidPort(Int)
  case sshConfigHostNotFound(String)
  case sshConfigHostNotConnectable(String)
  case serverNotReady
  case sshLaunchFailed(String)
  case browserOpenRejected(String)
  case browserOpenRequestNotFound(String)
  case browserOpenRequestNotPending(String)

  public var errorDescription: String? {
    switch self {
    case .emptyDestination:
      return "SSH destination is required."
    case .activeSessionExists:
      return "A managed SSH session is already active."
    case .noActiveSession:
      return "No active SSH session is available."
    case .sessionNotReady:
      return "The active SSH session is not ready."
    case .invalidBrowserURL(let value):
      return "Invalid browser URL: \(value)"
    case .unsupportedCallback(let value):
      return "No supported loopback callback port was found in: \(value)"
    case .invalidPort(let port):
      return "Invalid TCP port: \(port)"
    case .sshConfigHostNotFound(let alias):
      return "SSH config Host was not found: \(alias)"
    case .sshConfigHostNotConnectable(let alias):
      return "SSH config Host is not a concrete connectable alias: \(alias)"
    case .serverNotReady:
      return "The local browser bridge server did not become ready."
    case .sshLaunchFailed(let message):
      return message.isEmpty ? "Failed to launch ssh." : message
    case .browserOpenRejected(let message):
      return message.isEmpty ? "Browser open request was rejected." : message
    case .browserOpenRequestNotFound(let id):
      return "Browser open request was not found: \(id)"
    case .browserOpenRequestNotPending(let id):
      return "Browser open request is not waiting for approval: \(id)"
    }
  }
}
