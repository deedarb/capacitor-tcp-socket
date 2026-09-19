import Foundation
import Capacitor
import Socket

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(TcpSocketPlugin)
public class TcpSocketPlugin: CAPPlugin {
    /// A pooled connection: one from `connect` or one accepted by a listening socket.
    /// Reads are serialised on `readQueue`: BlueSocket's `Socket` is not thread-safe, and two
    /// concurrent reads would split one message between them. A serial queue per client (not one
    /// global one) so a silent peer does not block reads on the others.
    final class Client {
        let socket: Socket
        let readQueue = DispatchQueue(label: "tcp-socket.read", qos: .userInitiated)

        init(_ socket: Socket) {
            self.socket = socket
        }

        var isOpen: Bool { socket.socketfd != Socket.SOCKET_INVALID_DESCRIPTOR }
    }

    /// Client ids are indexes into this pool. The accept loop appends while JS keeps calling
    /// send/read, and a closed client keeps its slot so ids stay stable.
    private var clients: [Client] = []
    /// Only touched from the bridge queue (listen / stopListening), so no lock.
    private var servers: [Socket] = []

    /// Guards `clients`, and the close of a socket so "peer gone" is reported once.
    private let clientsLock = NSLock()

    /// Appends a client and returns its id, which is its index in the pool.
    private func addClient(_ socket: Socket) -> Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        clients.append(Client(socket))
        return clients.count - 1
    }

    private func client(at index: Int) -> Client? {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients[safe: index]
    }

    /// Closes the client and tells JS the peer is gone — once: only the close that actually
    /// closes the socket emits the event, and a local `disconnect` is not a peer event.
    private func peerGone(_ index: Int, _ client: Client) {
        clientsLock.lock()
        let wasOpen = client.isOpen
        if wasOpen { client.socket.close() }
        clientsLock.unlock()
        if wasOpen {
            notifyListeners("disconnection", data: ["client": index])
        }
    }

    @objc func connect(_ call: CAPPluginCall) {
        guard let ip = call.getString("ipAddress") else {
            call.reject("Must provide ip address to connect")
            return
        }
        let port = Int32(call.getInt("port", 9100))
        let timeout = UInt(call.getInt("timeout", 10) * 1000) // Default 10 second timeout

        do {
            let socket = try Socket.create()
            try socket.connect(to: ip, port: port, timeout: timeout)
            call.resolve(["client": addClient(socket)])
        } catch {
            call.reject(error.localizedDescription)
        }
    }

    @objc func send(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if clientIndex == -1 {
            call.reject("No client specified")
            return
        }

        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index")
            return
        }
        guard client.isOpen else {
            call.reject("Socket closed")
            return
        }

        guard let base64Data = call.getString("data") else {
            call.reject("No data provided")
            return
        }
        // Decode base64 string to raw Data
        guard let decodedData = Data(base64Encoded: base64Data) else {
            call.reject("Invalid base64 data")
            return
        }

        do {
            // Send the raw data
            try client.socket.write(from: decodedData)
            call.resolve()
        } catch {
            if !client.isOpen {
                call.reject("Socket closed")
            } else {
                // Broken pipe / connection reset: the peer is gone.
                peerGone(clientIndex, client)
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func read(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if clientIndex == -1 {
            call.reject("No client specified")
            return
        }

        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index")
            return
        }
        guard client.isOpen else {
            call.reject("Socket closed")
            return
        }

        let expectLen = max(1, call.getInt("expectLen", 1024))
        // 0 = only what is already there; negative would make poll() wait forever.
        let timeoutMs = max(0, call.getInt("timeout", 10)) * 1000

        // The bridge serves every plugin call from one serial queue: a read that blocks here
        // would stall all other plugin calls (printing included) until data arrives. Wait for
        // readability on the client's own queue, and give up after `timeout` instead of hanging
        // forever on a peer that connected and went silent.
        client.readQueue.async { [weak self] in
            guard let self = self else { return }
            let fd = client.socket.socketfd
            guard fd != Socket.SOCKET_INVALID_DESCRIPTOR else {
                call.reject("Socket closed")
                return
            }

            // Not BlueSocket's isReadableOrWritable: it selects on read AND write, and a freshly
            // accepted socket is always writable, so it returns at once with nothing to read.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(clamping: timeoutMs))
            if ready == 0 {
                // Peer connected and went silent: not an error for the caller, just nothing to read.
                call.resolve(["result": ""])
                return
            }
            if ready < 0 {
                call.reject(String(cString: strerror(errno)))
                return
            }
            // disconnect() may have closed the socket while we were waiting; the descriptor
            // number could already belong to a new socket, so do not touch it.
            guard client.socket.socketfd == fd else {
                call.reject("Socket closed")
                return
            }

            // One recv, at most `expectLen` bytes — same as Android. Not BlueSocket's read(into:):
            // it ignores the length, reads everything available, and when the peer sent exactly a
            // multiple of its buffer size it blocks on one more recv despite the poll above.
            var buffer = [UInt8](repeating: 0, count: expectLen)
            let count = Darwin.recv(fd, &buffer, expectLen, 0)
            if count > 0 {
                // Raw bytes as base64: the caller decides how to decode them.
                call.resolve(["result": Data(bytes: buffer, count: count).base64EncodedString()])
            } else if count == 0 {
                // End of stream: the peer closed. Report it once; further reads are rejected.
                self.peerGone(clientIndex, client)
                call.resolve(["result": ""])
            } else {
                let err = errno
                if client.socket.socketfd != fd {
                    call.reject("Socket closed")
                } else {
                    // Connection reset and the like: the peer is gone.
                    self.peerGone(clientIndex, client)
                    call.reject(String(cString: strerror(err)))
                }
            }
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if clientIndex == -1 {
            call.reject("No client specified")
            return
        }

        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index")
            return
        }
        // Idempotent: closing a closed socket is a no-op. A read waiting on this socket
        // gets "Socket closed" from its own queue.
        clientsLock.lock()
        client.socket.close()
        clientsLock.unlock()
        call.resolve(["client": clientIndex])
    }

    @objc func listen(_ call: CAPPluginCall) {
        let port = call.getInt("port", 9100)

        do {
            let server = try Socket.create()
            try server.listen(on: port)
            servers.append(server)
            let serverIndex = servers.count - 1

            // acceptClientConnection() blocks until a peer arrives, so the loop
            // cannot run on the thread serving JS calls.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                while true {
                    guard let self = self else { return }
                    guard let accepted = try? server.acceptClientConnection() else {
                        // listen socket closed by stopListening, or accept failed
                        return
                    }
                    let clientIndex = self.addClient(accepted)
                    // Retained: a peer may connect before JS has attached its listener,
                    // and the client would otherwise be unreachable from JS.
                    self.notifyListeners("connection", data: [
                        "server": serverIndex,
                        "client": clientIndex,
                        "address": accepted.remoteHostname
                    ], retainUntilConsumed: true)
                }
            }
            call.resolve(["server": serverIndex])
        } catch {
            call.reject(error.localizedDescription)
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
            call.reject("No server specified")
            return
        }

        guard let server = servers[safe: serverIndex] else {
            call.reject("Invalid server index")
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
