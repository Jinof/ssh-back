import Foundation

public enum BrowserOpenHookKind: String, Equatable {
  case confirmBrowserOpen = "confirm_browser_open"
  case custom
}

public enum BrowserOpenHookDecision: Equatable {
  case allow
  case deny(String)
}

public struct BrowserOpenHookContext: Equatable {
  public var sessionId: String
  public var targetName: String
  public var url: String
  public var callbackHost: String
  public var callbackPort: Int

  public init(
    sessionId: String,
    targetName: String,
    url: String,
    callbackHost: String,
    callbackPort: Int
  ) {
    self.sessionId = sessionId
    self.targetName = targetName
    self.url = url
    self.callbackHost = callbackHost
    self.callbackPort = callbackPort
  }
}

public struct BrowserOpenHook {
  public var name: String
  public var kind: BrowserOpenHookKind
  public var enabled: Bool

  private let handler: (BrowserOpenHookContext) -> BrowserOpenHookDecision

  public init(
    name: String,
    kind: BrowserOpenHookKind = .custom,
    enabled: Bool = true,
    handler: @escaping (BrowserOpenHookContext) -> BrowserOpenHookDecision
  ) {
    self.name = name
    self.kind = kind
    self.enabled = enabled
    self.handler = handler
  }

  public func evaluate(_ context: BrowserOpenHookContext) -> BrowserOpenHookDecision {
    guard enabled else {
      return .allow
    }

    return handler(context)
  }
}
