import Foundation

public struct CallbackEndpoint: Equatable {
  public var host: String
  public var port: Int
}

public enum CallbackParser {
  public static func parse(from urlString: String) -> CallbackEndpoint? {
    guard let components = URLComponents(string: urlString) else {
      return nil
    }

    if let endpoint = endpoint(from: components) {
      return endpoint
    }

    for candidate in nestedURLCandidates(from: components) {
      if let endpoint = parse(from: candidate) {
        return endpoint
      }
    }

    return nil
  }

  public static func isSupportedLoopbackHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "localhost"
      || normalized == "127.0.0.1"
      || normalized == "::1"
      || normalized == "[::1]"
  }

  public static func isSupportedCallbackPort(_ port: Int) -> Bool {
    (1024...65535).contains(port)
  }

  private static func endpoint(from components: URLComponents) -> CallbackEndpoint? {
    guard
      let host = components.host,
      let port = components.port,
      isSupportedLoopbackHost(host),
      isSupportedCallbackPort(port)
    else {
      return nil
    }

    return CallbackEndpoint(host: host, port: port)
  }

  private static func nestedURLCandidates(from components: URLComponents) -> [String] {
    var candidates: [String] = []

    if let queryItems = components.queryItems {
      for item in queryItems {
        if let value = item.value {
          candidates.append(value)
        }
      }
    }

    if let fragment = components.fragment {
      candidates.append(fragment)

      if let fragmentComponents = URLComponents(string: "http://ssh-back.local?\(fragment)"),
         let queryItems = fragmentComponents.queryItems {
        for item in queryItems {
          if let value = item.value {
            candidates.append(value)
          }
        }
      }
    }

    return candidates.filter { value in
      value.contains("localhost")
        || value.contains("127.0.0.1")
        || value.contains("%3A%2F%2F")
        || value.contains("::1")
    }
  }
}
