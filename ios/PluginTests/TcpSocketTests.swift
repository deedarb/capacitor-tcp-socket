import XCTest
import Capacitor
import Socket
@testable import Plugin

/// Drives the plugin the way the bridge does — one `CAPPluginCall` per method call — against
/// peers on the loopback interface, and checks what JS would see: results, events, error codes.
final class TcpSocketTests: XCTestCase {
    private enum Outcome {
        case resolved([String: Any])
        case rejected(code: String?, message: String)
    }

    private var plugin: TcpSocketPlugin!
    private var peers: [Socket] = []

    override func setUp() {
        super.setUp()
        plugin = TcpSocketPlugin()
        // Set up by the bridge's initializer, which a plugin under test does not go through.
        plugin.eventListeners = NSMutableDictionary()
        plugin.retainedEventArguments = NSMutableDictionary()
    }

    override func tearDown() {
        peers.forEach { $0.close() }
        peers = []
        plugin = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func invoke(_ method: String, _ options: [String: Any] = [:], timeout: TimeInterval = 5) -> Outcome {
        let done = expectation(description: method)
        var outcome: Outcome?
        let call = CAPPluginCall(callbackId: method, methodName: method, options: options, success: { result, _ in
            outcome = .resolved(result?.data ?? [:])
            done.fulfill()
        }, error: { error in
            outcome = .rejected(code: error?.code, message: error?.message ?? "")
            done.fulfill()
        })!
        switch method {
        case "connect": plugin.connect(call)
        case "send": plugin.send(call)
        case "read": plugin.read(call)
        case "disconnect": plugin.disconnect(call)
        case "listen": plugin.listen(call)
        case "stopListening": plugin.stopListening(call)
        case "getLocalAddress": plugin.getLocalAddress(call)
        default: XCTFail("no such method: \(method)")
        }
        wait(for: [done], timeout: timeout)
        return outcome ?? .rejected(code: nil, message: "not settled")
    }

    private func resolved(_ method: String, _ options: [String: Any] = [:],
                          file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        switch invoke(method, options) {
        case .resolved(let data):
            return data
        case .rejected(let code, let message):
            XCTFail("\(method) rejected: \(code ?? "nil") \(message)", file: file, line: line)
            return [:]
        }
    }

    private func assertRejects(_ method: String, _ options: [String: Any] = [:], code: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch invoke(method, options) {
        case .resolved(let data):
            XCTFail("\(method) resolved with \(data), expected \(code)", file: file, line: line)
        case .rejected(let actual, let message):
            XCTAssertEqual(actual, code, message, file: file, line: line)
        }
    }

    /// Records the events JS would get for `eventName`.
    private func listen(for eventName: String, onEvent: @escaping ([String: Any]) -> Void) {
        let listener = CAPPluginCall(callbackId: eventName, methodName: "addListener",
                                     options: ["eventName": eventName], success: { result, _ in
            onEvent(result?.data ?? [:])
        }, error: { _ in })!
        plugin.addEventListener(eventName, listener: listener)
    }

    /// A listening socket on a free loopback port, standing in for the device on the other end.
    private func makePeerServer() throws -> Socket {
        let server = try Socket.create()
        try server.listen(on: 0, node: "127.0.0.1")
        peers.append(server)
        return server
    }

    /// A loopback port nothing listens on, held for the rest of the test: bound but not listening,
    /// so no other process can take it meanwhile. Darwin answers a connect to it with nothing at
    /// all, so the connect runs into its timeout.
    private func silentPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        addTeardownBlock { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        XCTAssertTrue(bound, String(cString: strerror(errno)))
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Connects the plugin to a fresh peer and returns the client id and the peer's end.
    private func connectedPair() throws -> (client: Int, peer: Socket) {
        let server = try makePeerServer()
        var accepted: Socket?
        let acceptedPeer = expectation(description: "accept")
        DispatchQueue.global().async {
            accepted = try? server.acceptClientConnection()
            acceptedPeer.fulfill()
        }
        let result = resolved("connect", ["ipAddress": "127.0.0.1", "port": Int(server.listeningPort), "timeout": 5])
        wait(for: [acceptedPeer], timeout: 5)
        let peer = try XCTUnwrap(accepted)
        peers.append(peer)
        return (try XCTUnwrap(result["client"] as? Int), peer)
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    // MARK: - Error codes

    func testInvalidOptionsRejectWithInvalidArgument() {
        assertRejects("connect", [:], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("send", ["data": ""], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("send", ["client": 42, "data": ""], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("read", ["client": 42], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("disconnect", [:], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("disconnect", ["client": 42], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("stopListening", [:], code: TcpSocketPlugin.ErrorCode.invalidArgument)
        assertRejects("stopListening", ["server": 42], code: TcpSocketPlugin.ErrorCode.invalidArgument)
    }

    func testTimedOutConnectRejectsWithConnectFailed() throws {
        let port = try silentPort()
        assertRejects("connect", ["ipAddress": "127.0.0.1", "port": port, "timeout": 1],
                      code: TcpSocketPlugin.ErrorCode.connectFailed)
    }

    func testInvalidBase64RejectsWithInvalidArgument() throws {
        let (client, _) = try connectedPair()
        assertRejects("send", ["client": client, "data": "%%%"], code: TcpSocketPlugin.ErrorCode.invalidArgument)
    }

    // MARK: - Client

    func testSendAndReadRoundTrip() throws {
        let (client, peer) = try connectedPair()

        _ = resolved("send", ["client": client, "data": base64("hello")])
        var received = Data()
        _ = try peer.read(into: &received)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "hello")

        try peer.write(from: "world")
        let result = resolved("read", ["client": client, "expectLen": 1024, "timeout": 5])
        XCTAssertEqual(result["result"] as? String, base64("world"))
    }

    func testReadHonoursExpectLen() throws {
        let (client, peer) = try connectedPair()
        try peer.write(from: "abcdef")

        let first = resolved("read", ["client": client, "expectLen": 4, "timeout": 5])
        let second = resolved("read", ["client": client, "expectLen": 4, "timeout": 5])
        XCTAssertEqual(first["result"] as? String, base64("abcd"))
        XCTAssertEqual(second["result"] as? String, base64("ef"))
    }

    func testReadOnASilentPeerResolvesEmptyAfterTimeout() throws {
        let (client, _) = try connectedPair()
        let result = resolved("read", ["client": client, "expectLen": 16, "timeout": 0])
        XCTAssertEqual(result["result"] as? String, "")
    }

    func testPeerCloseFiresDisconnectionOnceAndLaterCallsRejectClosed() throws {
        let (client, peer) = try connectedPair()
        var disconnected: [Int] = []
        listen(for: "disconnection") { disconnected.append($0["client"] as? Int ?? -1) }

        peer.close()
        let result = resolved("read", ["client": client, "expectLen": 16, "timeout": 5])
        XCTAssertEqual(result["result"] as? String, "")
        XCTAssertEqual(disconnected, [client])

        assertRejects("read", ["client": client], code: TcpSocketPlugin.ErrorCode.closed)
        assertRejects("send", ["client": client, "data": base64("x")], code: TcpSocketPlugin.ErrorCode.closed)
        XCTAssertEqual(disconnected, [client])
    }

    func testDisconnectIsIdempotentAndClosesTheClient() throws {
        let (client, _) = try connectedPair()
        var disconnected = 0
        listen(for: "disconnection") { _ in disconnected += 1 }

        XCTAssertEqual(resolved("disconnect", ["client": client])["client"] as? Int, client)
        XCTAssertEqual(resolved("disconnect", ["client": client])["client"] as? Int, client)
        assertRejects("send", ["client": client, "data": base64("x")], code: TcpSocketPlugin.ErrorCode.closed)
        assertRejects("read", ["client": client], code: TcpSocketPlugin.ErrorCode.closed)
        // A local disconnect is not a peer event.
        XCTAssertEqual(disconnected, 0)
    }

    // MARK: - Server

    func testListenEmitsConnectionForAnAcceptedPeer() throws {
        let connected = expectation(description: "connection")
        var event: [String: Any] = [:]
        listen(for: "connection") {
            event = $0
            connected.fulfill()
        }

        // Port 0: the system picks a free one, and listen reports it.
        let listening = resolved("listen", ["port": 0])
        let server = try XCTUnwrap(listening["server"] as? Int)
        let port = try XCTUnwrap(listening["port"] as? Int)
        XCTAssertGreaterThan(port, 0)
        let peer = try Socket.create()
        peers.append(peer)
        try peer.connect(to: "127.0.0.1", port: Int32(port))
        wait(for: [connected], timeout: 5)

        XCTAssertEqual(event["server"] as? Int, server)
        XCTAssertEqual(event["address"] as? String, "127.0.0.1")
        let client = try XCTUnwrap(event["client"] as? Int)

        // The accepted peer is an ordinary client.
        try peer.write(from: "ping")
        XCTAssertEqual(resolved("read", ["client": client, "expectLen": 16, "timeout": 5])["result"] as? String,
                       base64("ping"))

        _ = resolved("stopListening", ["server": server])
        // Idempotent, and the accepted client stays open.
        _ = resolved("stopListening", ["server": server])
        _ = resolved("send", ["client": client, "data": base64("pong")])
    }

    func testConnectionBeforeAnyListenerIsRetained() throws {
        let port = try XCTUnwrap(resolved("listen", ["port": 0])["port"] as? Int)
        let peer = try Socket.create()
        peers.append(peer)
        try peer.connect(to: "127.0.0.1", port: Int32(port))

        // Delivered to the first listener, however late it comes.
        let connected = expectation(description: "connection")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.listen(for: "connection") { _ in connected.fulfill() }
        }
        wait(for: [connected], timeout: 5)
    }
}
