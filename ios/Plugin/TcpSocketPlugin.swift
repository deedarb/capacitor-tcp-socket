import Foundation
import Capacitor
import Socket

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(TcpSocketPlugin)
public class TcpSocketPlugin: CAPPlugin {
    var clients: [Socket] = []
    var servers: [Socket] = []

    /// Guards `clients`: with a listening socket the array is also appended to
    /// from the accept loop, while JS keeps calling send/read on the main thread.
    private let clientsLock = NSLock()

    /// Appends a client and returns its id, which is its index in the pool.
    private func addClient(_ client: Socket) -> Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        clients.append(client)
        return clients.count - 1
    }

    private func client(at index: Int) -> Socket? {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients[safe: index]
    }

    @objc func connect(_ call: CAPPluginCall) {
        guard let ip = call.getString("ipAddress") else {
            call.reject("Must provide ip address to connect")
            return
        }
        let port = Int32(call.getInt("port", 9100))
        let timeout = UInt(call.getInt("timeout", 10) * 1000) // Default 10 second timeout
        
        do {
            let client = try Socket.create()
            try client.connect(to: ip, port: port, timeout: timeout)
            call.resolve(["client": addClient(client)])
        } catch {
            call.reject(error.localizedDescription)
        }
    }
    
    @objc func send(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if (clientIndex == -1) {
            call.reject("No client specified")
            return
        }
        
        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index")
            return
        }
        
        guard let base64Data = call.getString("data") else {
            call.reject("No data provided")
            return
        }
        
        do {
            // Decode base64 string to raw Data
            guard let decodedData = Data(base64Encoded: base64Data) else {
                call.reject("Invalid base64 data")
                return
            }
            
            // Send the raw data
            try client.write(from: decodedData)
            call.resolve()
        } catch {
            call.reject(error.localizedDescription)
        }
    }
    
    @objc func read(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if (clientIndex == -1) {
            call.reject("No client specified")
            return
        }
        
        guard let client = client(at: clientIndex) else {
            call.reject("Invalid client index")
            return
        }
        
        let expectLen = call.getInt("expectLen", 1024)
        let timeout = call.getInt("timeout", 10)
        
        var buffer = Data(capacity: expectLen)
        do {
            let bytesRead = try client.read(into: &buffer)
            if bytesRead > 0 {
                // Return the raw data as base64 string
                let base64String = buffer.base64EncodedString()
                call.resolve(["result": base64String])
            } else {
                call.resolve(["result": ""])
            }
        } catch {
            call.resolve(["result": ""])
        }
    }
    
    @objc func disconnect(_ call: CAPPluginCall) {
        let clientIndex = call.getInt("client", -1)
        if (clientIndex == -1) {
            call.reject("No client specified")
            return
        }
        
        if let client = client(at: clientIndex) {
            client.close()
        }
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
                    self.notifyListeners("connection", data: [
                        "server": serverIndex,
                        "client": clientIndex,
                        "address": accepted.remoteHostname
                    ])
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
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
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
        if (serverIndex == -1) {
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
