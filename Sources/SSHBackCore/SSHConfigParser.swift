import Foundation

public enum SSHConfigParser {
  public static func parse(contents: String, sourcePath: String, loadedAt: Date = Date()) -> [SshConfigHost] {
    var blocks: [HostBlock] = []
    var currentBlock: HostBlock?

    for rawLine in contents.components(separatedBy: .newlines) {
      let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else {
        continue
      }

      let tokens = shellLikeTokens(from: line)
      guard let keyword = tokens.first?.lowercased() else {
        continue
      }

      if keyword == "host" {
        if let block = currentBlock {
          blocks.append(block)
        }
        currentBlock = HostBlock(patterns: Array(tokens.dropFirst()))
        continue
      }

      guard var block = currentBlock, tokens.count >= 2 else {
        continue
      }

      let value = tokens.dropFirst().joined(separator: " ")
      switch keyword {
      case "hostname":
        block.hostName = value
      case "user":
        block.user = value
      case "port":
        block.port = Int(value)
      default:
        break
      }
      currentBlock = block
    }

    if let block = currentBlock {
      blocks.append(block)
    }

    var hostsByAlias: [String: SshConfigHost] = [:]
    for block in blocks {
      for pattern in block.patterns {
        let alias = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
          continue
        }

        let connectable = isConnectableHostAlias(alias)
        if hostsByAlias[alias] == nil {
          hostsByAlias[alias] = SshConfigHost(
            alias: alias,
            sourcePath: sourcePath,
            hostName: block.hostName,
            user: block.user,
            port: block.port,
            connectable: connectable,
            loadedAt: loadedAt
          )
        }
      }
    }

    return hostsByAlias.values.sorted {
      $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
    }
  }

  public static func isConnectableHostAlias(_ alias: String) -> Bool {
    !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!")
  }

  private static func stripComment(from line: String) -> String {
    var result = ""
    var isQuoted = false
    var previousWasBackslash = false

    for character in line {
      if character == "\\" && !previousWasBackslash {
        previousWasBackslash = true
        result.append(character)
        continue
      }

      if character == "\"" && !previousWasBackslash {
        isQuoted.toggle()
      }

      if character == "#" && !isQuoted {
        break
      }

      previousWasBackslash = false
      result.append(character)
    }

    return result
  }

  private static func shellLikeTokens(from line: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var isQuoted = false
    var previousWasBackslash = false

    for character in line {
      if character == "\\" && !previousWasBackslash {
        previousWasBackslash = true
        continue
      }

      if character == "\"" && !previousWasBackslash {
        isQuoted.toggle()
        continue
      }

      if character.isWhitespace && !isQuoted {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }

      previousWasBackslash = false
    }

    if !current.isEmpty {
      tokens.append(current)
    }

    return tokens
  }
}

private struct HostBlock {
  var patterns: [String]
  var hostName: String?
  var user: String?
  var port: Int?
}
