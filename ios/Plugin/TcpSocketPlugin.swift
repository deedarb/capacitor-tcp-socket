import Foundation
import Capacitor
import Socket

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(TcpSocketPlugin)
public class TcpSocketPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TcpSocketPlugin"
    public let jsName = "TcpSocket"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "read", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopListening", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLocalAddress", returnType: CAPPluginReturnPromise)
    ]

    /// A pooled connection: one from `connect` or one accepted by a listening socket.
    /// Reads are serialised on `readQueue`: BlueSocket's `Socket` is not thread-safe, and two
    /// concurrent reads would split one message between them. A serial queue per client (not one
    /// global one) so a silent peer does not block reads on the others. Writes likewise go one at
    /// a time, in call order, on `writeQueue`: off the bridge queue, but never reordered.
    final class Client {
        let socket: Socket
        let readQueue = DispatchQueue(label: "tcp-socket.read", qos: .userInitiated)
        let writeQueue = DispatchQueue(label: "tcp-socket.write", qos: .userInitiated)
        /// Guards every close of this socket and each send/recv on it: a descriptor checked under
        /// it is still this client's own, never a number already handed to a new socket, and
        /// "peer gone" is reported once. Per client, so busy peers do not wait on each other.
        let lock = NSLock()

        init(_ socket: Socket) {
            self.socket = socket
        }

        var isOpen: Bool { socket.socketfd != Socket.SOCKET_INVALID_DESCRIPTOR }
    }

    /// Client ids are indexes into this pool. The accept loop and connects append while JS keeps
    /// calling send/read, and a closed client keeps its slot (as `closedClient`) so ids stay
    /// stable and are never reused.
    private var clients: [Client] = []
    /// Stand-in for a closed client: its slot keeps answering "Socket closed" (and `disconnect`
    /// stays idempotent) without holding on to the real socket and its buffers for good.
    /// Nil only if not even a socket could be created; closed clients then keep their slots.
    private let closedClient: Client? = TcpSocketPlugin.makeClosedClient()
    /// A closed server keeps its slot, so ids stay stable.
    private var servers: [Socket] = []
    private let serversLock = NSLock()

    /// Guards `clients` and `generation`, and the delivery of `connection` events.
    private let clientsLock = NSLock()
    /// Bumped by `closeAll()`: a connect or accept that started for an earlier page closes its
    /// socket instead of adding it to the pool.
    private var generation = 0

    /// Watches the web view for a new page; see `load()`.
    private var pageObservation: NSKeyValueObservation?

    override public func load() {
        // The bridge drops every event listener when the web view starts a new page (reload, live
        // update). Sockets the old page opened would outlive it unreachable: their ids are lost,
        // a listening one keeps its port. Close them all with the page that owned them.
        pageObservation = webView?.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            if change.newValue == true {
                self?.closeAll()
            }
        }
    }

    deinit {
        closeAll()
    }

    /// Closes every client and server, with no events: the page they belonged to is gone. Ids are
    /// not reused, so a stale one from the old page answers "Socket closed".
    private func closeAll() {
        clientsLock.lock()
        generation += 1
        // Retained for a listener that never came: the new page must not get the old one's clients.
        retainedEventArguments?.removeObject(forKey: "connection")
        let open = clients.enumerated().filter { $0.element !== closedClient }
        for (index, client) in open {
            releaseLocked(index, client)
        }
        clientsLock.unlock()
        for (_, client) in open {
            client.lock.lock()
            client.socket.close()
            client.lock.unlock()
        }
        serversLock.lock()
        let listening = servers
        serversLock.unlock()
        for server in listening {
            server.close()
        }
    }

    private func currentGeneration() -> Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return generation
    }

    /// Appends a client and returns its id, which is its index in the pool — or closes the socket
    /// and returns nil when the page it was opened for is gone. Caller holds `clientsLock`.
    private func addClientLocked(_ socket: Socket, pageGeneration: Int) -> Int? {
        guard pageGeneration == generation else {
            socket.close()
            return nil
        }
        clients.append(Client(socket))
        return clients.count - 1
    }

    private func client(at index: Int) -> Client? {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients[safe: index]
    }

    /// Rejection for a call whose work outlived the plugin (bridge torn down meanwhile).
    private static let pluginReleased = "Plugin released"

    /// `code` of a rejection, the same on every platform: `TcpSocketErrorCode` in definitions.ts.
    enum ErrorCode {
        static let invalidArgument = "INVALID_ARGUMENT"
        static let closed = "CLOSED"
        static let timeout = "TIMEOUT"
        static let connectFailed = "CONNECT_FAILED"
        static let listenFailed = "LISTEN_FAILED"
        static let ioError = "IO_ERROR"
    }

    /// Pause after the first failed accept, in seconds; doubled on each failure in a row, up to the max.
    private static let acceptRetryDelay = 0.2
    private static let acceptRetryMaxDelay = 5.0
    /// A listener whose accept keeps failing for this long is broken for good and is closed.
    private static let acceptGiveUpAfter = 60.0

    /// Settles a call once, from whichever of two threads gets there first.
    private final class Once {
        private let lock = NSLock()
        private var done = false

        /// True for the first caller only.
        func settle() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }

        var isSettled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done
        }
    }

    private static func isClosed(_ server: Socket) -> Bool {
        return server.socketfd == Socket.SOCKET_INVALID_DESCRIPTOR || !server.isListening
    }

    private static func makeClosedClient() -> Client? {
        guard let socket = try? Socket.create() else { return nil }
        socket.close()
        return Client(socket)
    }

    /// Frees the slot of a closed client; in-flight calls keep their own reference to it.
    /// Caller holds `clientsLock`.
    private func releaseLocked(_ index: Int, _ client: Client) {
        if let closed = closedClient, clients[safe: index] === client {
            clients[index] = closed
        }
    }

    /// Closes the client and tells JS the peer is gone — once: only the close that actually
    /// closes the socket emits the event, and a local `disconnect` is not a peer event.
    private func peerGone(_ index: Int, _ client: Client) {
        client.lock.lock()
        let wasOpen = client.isOpen
        if wasOpen { client.socket.close() }
        client.lock.unlock()
        clientsLock.lock()
        releaseLocked(index, client)
        clientsLock.unlock()
        if wasOpen {
            notifyListeners("disconnection", data: ["client": index])
        }
    }

    @objc func connect(_ call: CAPPluginCall) {
        guard let ip = call.getString("ipAddress") else {
            call.reject("Must provide ip address to connect", ErrorCode.invalidArgument)
            return
        }
        let port = Int32(call.getInt("port", 9100))
        // Default 10 seconds; clamped so the conversion to milliseconds cannot overflow.
        let timeout = UInt(min(max(0, call.getInt("timeout", 10)), Int(Int32.max)) * 1000)

        // connect() blocks up to `timeout` on an unreachable address, and the bridge serves every
        // plugin call from one serial queue: run there, it would stall printing, reads and sends
        // to live peers until it gives up. Ids are handed out under the lock, so connects finishing
        // at once still get distinct ids.
        let pageGeneration = currentGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                call.reject(TcpSocketPlugin.pluginReleased, ErrorCode.closed)
                return
            }
            do {
                let socket = try Socket.create()
                do {
                    try socket.connect(to: ip, port: port, timeout: timeout)
                } catch {
                    socket.close()
                    throw error
                }
                self.clientsLock.lock()
                let clientIndex = self.addClientLocked(socket, pageGeneration: pageGeneration)
                self.clientsLock.unlock()
                guard let index = clientIndex else {
                    // The page reloaded while connecting: nobody is left to use this socket.
                    call.reject("Socket closed", ErrorCode.closed)
                    return
                }
                call.resolve(["client": index])
            } catch {
                call.reject(error.localizedDescription, ErrorCode.connectFailed)
            }
        }
    }

    @objc func send(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if clientIndex == -1 {
            call.reject("No client specified", ErrorCode.invalidArgument)
            return
        }

        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index", ErrorCode.invalidArgument)
            return
        }
        guard client.isOpen else {
            call.reject("Socket closed", ErrorCode.closed)
            return
        }

        guard let base64Data = call.getString("data") else {
            call.reject("No data provided", ErrorCode.invalidArgument)
            return
        }
        // Decode base64 string to raw Data
        guard let decodedData = Data(base64Encoded: base64Data) else {
            call.reject("Invalid base64 data", ErrorCode.invalidArgument)
            return
        }

        // Seconds; 0 (the default) = no limit, as before. Clamped so the deadline arithmetic
        // cannot overflow (68 years is no limit in practice).
        let timeoutSec = min(max(0, call.getInt("timeout", 0)), Int(Int32.max))

        // Settled once: by the write, or by the timeout — whichever comes first.
        let once = Once()
        // Counted from the call, not from when the write queue gets to it: a send queued behind a
        // stuck one still times out, and closing the socket frees both.
        let watchdog: DispatchWorkItem? = timeoutSec == 0 ? nil : DispatchWorkItem { [weak self] in
            guard once.settle() else { return }
            // The peer is not reading; the socket is of no use with half a message in it.
            // The write loop notices the close within a second and stops.
            self?.peerGone(clientIndex, client)
            call.reject("Send timed out", ErrorCode.timeout)
        }
        if let watchdog = watchdog {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(timeoutSec), execute: watchdog)
        }

        // A write blocks for as long as the peer does not read and the buffers stay full: run on
        // the bridge queue it would stall every other plugin call meanwhile. The client's own
        // queue keeps writes in call order.
        client.writeQueue.async { [weak self] in
            guard let self = self else {
                if once.settle() {
                    watchdog?.cancel()
                    call.reject(TcpSocketPlugin.pluginReleased, ErrorCode.closed)
                }
                return
            }
            // Timed out while queued: the socket is closed already.
            if once.isSettled { return }
            let outcome = self.writeAll(decodedData, to: client)
            // The timeout closed the socket under this write and has rejected the call.
            guard once.settle() else { return }
            watchdog?.cancel()
            switch outcome {
            case .sent:
                call.resolve()
            case .closed:
                call.reject("Socket closed", ErrorCode.closed)
            case .failed(let err):
                // Broken pipe / connection reset: the peer is gone.
                self.peerGone(clientIndex, client)
                call.reject(String(cString: strerror(err)), ErrorCode.ioError)
            }
        }
    }

    private enum WriteOutcome {
        case sent
        case closed
        case failed(Int32)
    }

    /// Writes all of `data` until done or the socket is closed (by `disconnect`, or by the send
    /// timeout). Not BlueSocket's write: on a blocking socket it waits in send() for as long as the
    /// peer does not read, with no way out. Each send() here does not block (MSG_DONTWAIT) and runs
    /// under the client's lock, where every close happens: the descriptor checked there is still
    /// this client's own, never a number already handed to a new socket. With the buffers full it
    /// waits in poll() outside the lock, a second at most, so a close made meanwhile is noticed.
    private func writeAll(_ data: Data, to client: Client) -> WriteOutcome {
        let fd = client.socket.socketfd
        guard fd != Socket.SOCKET_INVALID_DESCRIPTOR else { return .closed }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> WriteOutcome in
            guard let base = raw.baseAddress else { return .sent } // nothing to send
            var sent = 0
            while sent < raw.count {
                client.lock.lock()
                guard client.socket.socketfd == fd else {
                    // disconnect(), peerGone() or closeAll() closed it.
                    client.lock.unlock()
                    return .closed
                }
                // SIGPIPE is off: BlueSocket sets SO_NOSIGPIPE on every socket it creates or accepts.
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, MSG_DONTWAIT)
                let err = errno
                client.lock.unlock()
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0 && err == EINTR {
                    continue
                }
                if count < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                    // The buffers are full: wait for room. Should the socket be closed (and its
                    // number reused) meanwhile, poll only wakes early; the check above catches it.
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    continue
                }
                return .failed(count < 0 ? err : EIO)
            }
            return .sent
        }
    }

    @objc func read(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if clientIndex == -1 {
            call.reject("No client specified", ErrorCode.invalidArgument)
            return
        }

        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index", ErrorCode.invalidArgument)
            return
        }
        guard client.isOpen else {
            call.reject("Socket closed", ErrorCode.closed)
            return
        }

        let expectLen = max(1, call.getInt("expectLen", 1024))
        // 0 = only what is already there; negative would make poll() wait forever.
        let timeoutMs = min(max(0, call.getInt("timeout", 10)), Int(Int32.max)) * 1000

        // The bridge serves every plugin call from one serial queue: a read that blocks here
        // would stall all other plugin calls (printing included) until data arrives. Wait for
        // readability on the client's own queue, and give up after `timeout` instead of hanging
        // forever on a peer that connected and went silent.
        client.readQueue.async { [weak self] in
            guard let self = self else {
                call.reject(TcpSocketPlugin.pluginReleased, ErrorCode.closed)
                return
            }
            let fd = client.socket.socketfd
            guard fd != Socket.SOCKET_INVALID_DESCRIPTOR else {
                call.reject("Socket closed", ErrorCode.closed)
                return
            }

            // Not BlueSocket's isReadableOrWritable: it selects on read AND write, and a freshly
            // accepted socket is always writable, so it returns at once with nothing to read.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            var ready = poll(&pfd, 1, Int32(clamping: timeoutMs))
            var pollError = errno
            while ready < 0 && pollError == EINTR {
                // A signal cut the wait short: wait out the rest of the timeout.
                let left = max(0, Int(deadline.timeIntervalSinceNow * 1000))
                ready = poll(&pfd, 1, Int32(clamping: left))
                pollError = errno
            }
            if ready == 0 {
                // Peer connected and went silent: not an error for the caller, just nothing to read.
                call.resolve(["result": ""])
                return
            }
            if ready < 0 {
                if client.socket.socketfd != fd {
                    call.reject("Socket closed", ErrorCode.closed)
                } else {
                    // IO_ERROR promises a closed client and a `disconnection` event.
                    self.peerGone(clientIndex, client)
                    call.reject(String(cString: strerror(pollError)), ErrorCode.ioError)
                }
                return
            }
            // One recv, at most `expectLen` bytes — same as Android. Not BlueSocket's read(into:):
            // it ignores the length, reads everything available, and when the peer sent exactly a
            // multiple of its buffer size it blocks on one more recv despite the poll above.
            // Under the client's lock, where every close happens: disconnect() may have closed the
            // socket while we were waiting, and its number could already belong to a new socket.
            var buffer = [UInt8](repeating: 0, count: expectLen)
            client.lock.lock()
            guard client.socket.socketfd == fd else {
                client.lock.unlock()
                call.reject("Socket closed", ErrorCode.closed)
                return
            }
            let count = Darwin.recv(fd, &buffer, expectLen, MSG_DONTWAIT)
            let err = errno
            client.lock.unlock()
            if count > 0 {
                // Raw bytes as base64: the caller decides how to decode them.
                call.resolve(["result": Data(bytes: buffer, count: count).base64EncodedString()])
            } else if count == 0 {
                // End of stream: the peer closed. Report it once; further reads are rejected.
                self.peerGone(clientIndex, client)
                call.resolve(["result": ""])
            } else if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                // poll() reported data that is no longer there: nothing to read after all.
                call.resolve(["result": ""])
            } else {
                if client.socket.socketfd != fd {
                    call.reject("Socket closed", ErrorCode.closed)
                } else {
                    // Connection reset and the like: the peer is gone.
                    self.peerGone(clientIndex, client)
                    call.reject(String(cString: strerror(err)), ErrorCode.ioError)
                }
            }
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if clientIndex == -1 {
            call.reject("No client specified", ErrorCode.invalidArgument)
            return
        }

        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index", ErrorCode.invalidArgument)
            return
        }
        // Idempotent: closing a closed socket is a no-op. A read waiting on this socket
        // gets "Socket closed" from its own queue.
        client.lock.lock()
        client.socket.close()
        client.lock.unlock()
        clientsLock.lock()
        releaseLocked(clientIndex, client)
        clientsLock.unlock()
        call.resolve(["client": clientIndex])
    }

    @objc func listen(_ call: CAPPluginCall) {
        let port = call.getInt("port", 9100)

        do {
            let server = try Socket.create()
            do {
                try server.listen(on: port)
            } catch {
                server.close()
                throw error
            }
            serversLock.lock()
            servers.append(server)
            let serverIndex = servers.count - 1
            serversLock.unlock()
            let pageGeneration = currentGeneration()

            // acceptClientConnection() blocks until a peer arrives, so the loop
            // cannot run on the thread serving JS calls.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var delay = TcpSocketPlugin.acceptRetryDelay
                var failingSince: Date?
                while true {
                    guard let self = self else { return }
                    let accepted: Socket
                    do {
                        accepted = try server.acceptClientConnection()
                        delay = TcpSocketPlugin.acceptRetryDelay
                        failingSince = nil
                    } catch {
                        // close() wakes the accept before BlueSocket marks the socket closed, so
                        // look again after the pause before taking this for a failure.
                        if !TcpSocketPlugin.isClosed(server) {
                            Thread.sleep(forTimeInterval: delay)
                        }
                        if TcpSocketPlugin.isClosed(server) {
                            // stopListening (or a page reload) closed the socket: the only way
                            // this loop ends, but for the one below.
                            return
                        }
                        // A failed accept (aborted handshake, out of descriptors, the network
                        // changing under the socket) says nothing about the next one: giving up at
                        // once would leave the app believing it still listens. Back off instead,
                        // and only a listener that fails for a whole minute is taken for broken.
                        if let since = failingSince {
                            if Date().timeIntervalSince(since) >= TcpSocketPlugin.acceptGiveUpAfter {
                                NSLog("TcpSocket: accept keeps failing, closing the listener: \(error)")
                                server.close()
                                return
                            }
                        } else {
                            failingSince = Date()
                            NSLog("TcpSocket: accept failed, retrying: \(error)")
                        }
                        delay = min(delay * 2, TcpSocketPlugin.acceptRetryMaxDelay)
                        continue
                    }
                    self.clientsLock.lock()
                    guard let clientIndex = self.addClientLocked(accepted, pageGeneration: pageGeneration) else {
                        // Accepted just as the page reloaded: closeAll() closes the server next.
                        self.clientsLock.unlock()
                        return
                    }
                    // Retained: a peer may connect before JS has attached its listener, and the
                    // client would otherwise be unreachable from JS. Under the lock, so closeAll()
                    // cannot run between the generation check and the event being retained.
                    self.notifyListeners("connection", data: [
                        "server": serverIndex,
                        "client": clientIndex,
                        "address": accepted.remoteHostname
                    ], retainUntilConsumed: true)
                    self.clientsLock.unlock()
                }
            }
            call.resolve(["server": serverIndex, "port": Int(server.listeningPort)])
        } catch {
            call.reject(error.localizedDescription, ErrorCode.listenFailed)
        }
    }

    /// Address of this device in the local network: the Wi-Fi interface (en0) first, IPv4 first.
    /// Peers reach the device at this address without internet; the app sends it with heartbeats.
    @objc func getLocalAddress(_ call: CAPPluginCall) {
        var candidates: [(name: String, ip: String, isV4: Bool)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            call.resolve([:])
            return
        }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            // RUNNING too: an interface that is up without a link keeps its stale address.
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            // Wi-Fi is en0; other en*/bridge interfaces come next, cellular (pdp_ip*) is useless to peers.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                var ip = String(cString: host)
                if let zone = ip.firstIndex(of: "%") { ip = String(ip[..<zone]) }
                let isV4 = family == UInt8(AF_INET)
                if !isV4 && ip.hasPrefix("fe80") { continue }
                candidates.append((name: name, ip: ip, isV4: isV4))
            }
        }
        let best = candidates.sorted { left, right in
            if left.name == "en0" && right.name != "en0" { return true }
            if left.name != "en0" && right.name == "en0" { return false }
            if left.isV4 != right.isV4 { return left.isV4 }
            return left.name < right.name
        }.first
        guard let found = best else {
            call.resolve([:])
            return
        }
        call.resolve(["ip": found.ip, "interfaceName": found.name])
    }

    @objc func stopListening(_ call: CAPPluginCall) {
        let serverIndex = call.getInt("server", -1)
        if serverIndex == -1 {
            call.reject("No server specified", ErrorCode.invalidArgument)
            return
        }

        serversLock.lock()
        let found = servers[safe: serverIndex]
        serversLock.unlock()
        guard let server = found else {
            call.reject("Invalid server index", ErrorCode.invalidArgument)
            return
        }

        // Closing the socket is what ends the accept loop: it makes the pending
        // acceptClientConnection() fail, and the loop returns.
        server.close()
        call.resolve()
    }
}

// Helper extension for safe array access
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
