import XCTest
@testable import SSHBackCore

final class SSHConfigParserTests: XCTestCase {
  func testParsesConcreteHostsWithDisplayOptions() {
    let contents = """
    Host devbox
      HostName dev.example.test
      User deploy
      Port 2222

    Host staging prod
      HostName bastion.example.test
    """

    let hosts = SSHConfigParser.parse(contents: contents, sourcePath: "~/.ssh/config")

    XCTAssertEqual(hosts.first(where: { $0.alias == "devbox" })?.hostName, "dev.example.test")
    XCTAssertEqual(hosts.first(where: { $0.alias == "devbox" })?.user, "deploy")
    XCTAssertEqual(hosts.first(where: { $0.alias == "devbox" })?.port, 2222)
    XCTAssertEqual(hosts.first(where: { $0.alias == "staging" })?.hostName, "bastion.example.test")
    XCTAssertEqual(hosts.first(where: { $0.alias == "prod" })?.hostName, "bastion.example.test")
  }

  func testMarksWildcardPatternsNonConnectable() {
    let contents = """
    Host *
      User default

    Host internal-*
      User deploy

    Host concrete
      HostName concrete.example.test
    """

    let hosts = SSHConfigParser.parse(contents: contents, sourcePath: "~/.ssh/config")

    XCTAssertEqual(hosts.first(where: { $0.alias == "*" })?.connectable, false)
    XCTAssertEqual(hosts.first(where: { $0.alias == "internal-*" })?.connectable, false)
    XCTAssertEqual(hosts.first(where: { $0.alias == "concrete" })?.connectable, true)
  }

  func testIgnoresCommentsOutsideQuotes() {
    let contents = """
    Host quoted # ignored
      HostName "dev#1.example.test" # real comment
    """

    let hosts = SSHConfigParser.parse(contents: contents, sourcePath: "~/.ssh/config")

    XCTAssertEqual(hosts.map(\.alias), ["quoted"])
    XCTAssertEqual(hosts.first?.hostName, "dev#1.example.test")
  }
}
