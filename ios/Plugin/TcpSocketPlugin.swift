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
            clients.append(client)
            call.resolve(["client": clients.count - 1])
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
        
        guard let client = clients[safe: clientIndex] else {
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
        
        guard let client = clients[safe: clientIndex] else {
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
        
        if let client = clients[safe: clientIndex] {
            client.close()
        }
        call.resolve(["client": clientIndex])
    }
}

// Helper extension for safe array access
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
