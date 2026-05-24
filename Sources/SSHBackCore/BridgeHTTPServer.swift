import Foundation
import Network

public struct BridgeHTTPResponse: Equatable {
  public var statusCode: Int
  public var reason: String
  public var body: String

  public init(statusCode: Int, reason: String, body: String) {
    self.statusCode = statusCode
    self.reason = reason
    self.body = body
  }

  public static func ok(_ body: String) -> BridgeHTTPResponse {
    BridgeHTTPResponse(statusCode: 200, reason: "OK", body: body)
  }

  public static func badRequest(_ body: String) -> BridgeHTTPResponse {
    BridgeHTTPResponse(statusCode: 400, reason: "Bad Request", body: body)
  }

  public static func notFound(_ body: String) -> BridgeHTTPResponse {
    BridgeHTTPResponse(statusCode: 404, reason: "Not Found", body: body)
  }

  public static func serverError(_ body: String) -> BridgeHTTPResponse {
    BridgeHTTPResponse(statusCode: 500, reason: "Internal Server Error", body: body)
  }
}

public final class BridgeHTTPServer {
  public typealias Handler = (String) -> BridgeHTTPResponse

  private let queue = DispatchQueue(label: "ssh-back.bridge-http")
  private let handler: Handler
  private var listener: NWListener?

  public private(set) var port: UInt16?

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  deinit {
    stop()
  }

  @discardableResult
  public func start(port requestedPort: UInt16 = 0) throws -> UInt16 {
    let nwPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
    let listener = try NWListener(using: .tcp, on: nwPort)
    let ready = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var startError: Error?
    var didBecomeReady = false

    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }

    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        stateLock.lock()
        didBecomeReady = true
        stateLock.unlock()
        ready.signal()
      case .failed(let error):
        stateLock.lock()
        startError = error
        stateLock.unlock()
        ready.signal()
      default:
        break
      }
    }

    self.listener = listener
    listener.start(queue: queue)

    if ready.wait(timeout: .now() + 3) == .timedOut {
      throw SSHBackError.serverNotReady
    }

    stateLock.lock()
    let error = startError
    let isReady = didBecomeReady
    stateLock.unlock()

    if let error {
      throw error
    }

    guard isReady, let actualPort = listener.port?.rawValue else {
      throw SSHBackError.serverNotReady
    }

    port = actualPort
    return actualPort
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    port = nil
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
      guard let self else {
        connection.cancel()
        return
      }

      let response: BridgeHTTPResponse
      if let data, let request = String(data: data, encoding: .utf8) {
        response = self.route(request: request)
      } else {
        response = .badRequest("Invalid request.")
      }

      self.send(response, on: connection)
    }
  }

  private func route(request: String) -> BridgeHTTPResponse {
    guard let firstLine = request.components(separatedBy: "\r\n").first else {
      return .badRequest("Missing HTTP request line.")
    }

    let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2, parts[0] == "GET" else {
      return .badRequest("Only GET is supported.")
    }

    return handler(parts[1])
  }

  private func send(_ response: BridgeHTTPResponse, on connection: NWConnection) {
    let body = Data(response.body.utf8)
    let header = """
    HTTP/1.1 \(response.statusCode) \(response.reason)\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Length: \(body.count)\r
    Connection: close\r
    \r

    """

    var data = Data(header.utf8)
    data.append(body)

    connection.send(content: data, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}
