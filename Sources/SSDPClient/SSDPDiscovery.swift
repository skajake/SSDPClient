import Foundation
import HeliumLogger
import LoggerAPI
import Socket

// MARK: Protocols

/// Delegate for service discovery
public protocol SSDPDiscoveryDelegate {
    /// Tells the delegate a requested service has been discovered.
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didDiscoverService service: SSDPService)

    /// Tells the delegate that the discovery ended due to an error.
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didFinishWithError error: Error)

    /// Tells the delegate that the discovery has started.
    func ssdpDiscoveryDidStart(_ discovery: SSDPDiscovery)

    /// Tells the delegate that the discovery has finished.
    func ssdpDiscoveryDidFinish(_ discovery: SSDPDiscovery)
}

public extension SSDPDiscoveryDelegate {
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didDiscoverService service: SSDPService) {}

    func ssdpDiscovery(_ discovery: SSDPDiscovery, didFinishWithError error: Error) {}

    func ssdpDiscoveryDidStart(_ discovery: SSDPDiscovery) {}

    func ssdpDiscoveryDidFinish(_ discovery: SSDPDiscovery) {}
}

/// SSDP discovery for UPnP devices on the LAN
public class SSDPDiscovery {

    /// The UDP socket
    private var socket: Socket?
    
    /// The client is discovering
    private var discovering: Bool = false

    /// Delegate for service discovery
    public var delegate: SSDPDiscoveryDelegate?

    // MARK: Initialisation

    public init() {
        HeliumLogger.use()
    }

    deinit {
        self.stop()
    }

    // MARK: Private functions

    /// Read responses.
    private func readResponses() {
        do {
            guard let socket = self.socket else {
                return
            }
            var data = Data()
            let (bytesRead, address) = try socket.readDatagram(into: &data)

            if bytesRead > 0 {
                let response = String(data: data, encoding: .utf8)
                let (remoteHost, _) = Socket.hostnameAndPort(from: address!)!
                Log.debug("Received: \(response!) from \(remoteHost)")
                self.delegate?.ssdpDiscovery(self, didDiscoverService: SSDPService(host: remoteHost, response: response!))
            }

        } catch let error {
            if discovering {
                Log.error("Socket error: \(error)")
                self.queueForceStop() { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.delegate?.ssdpDiscovery(strongSelf, didFinishWithError: error)
                }
            }
        }
    }

    /// Read responses with timeout.
    private func readResponses(forDuration duration: TimeInterval) {
        let queue = DispatchQueue.global()

        queue.async() {
            while self.discovering {
                self.readResponses()
            }
        }

        queue.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.discovering = false
            self?.stop()
        }
    }

    /// Force stop discovery closing the socket.
    private func forceStop() {
        if self.discovering,
           let socket = self.socket {
            socket.close()
        }
        self.socket = nil
    }

    // MARK: Public functions

    /**
        Discover SSDP services for a duration.
        - Parameters:
            - duration: The amount of time to wait.
            - searchTarget: The type of the searched service.
    */
    open func discoverService(forDuration duration: TimeInterval = 10, searchTarget: String = "ssdp:all", port: Int32 = 1900) {
        Log.info("Start SSDP discovery for \(Int(duration)) duration...")
        self.delegate?.ssdpDiscoveryDidStart(self)

        let message = "M-SEARCH * HTTP/1.1\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "HOST: 239.255.255.250:\(port)\r\n" +
            "ST: \(searchTarget)\r\n" +
            "MX: \(Int(duration))\r\n\r\n"

        do {
            self.socket = try Socket.create(type: .datagram, proto: .udp)
            discovering = true
            try self.socket!.listen(on: 0)

            self.readResponses(forDuration: duration)

            Log.debug("Send: \(message)")
            try self.socket?.write(from: message, to: Socket.createAddress(for: "239.255.255.250", on: port)!)

        } catch let error {
            Log.error("Socket error: \(error)")
            self.queueForceStop() { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.delegate?.ssdpDiscovery(strongSelf, didFinishWithError: error)
            }
        }
    }

    /// Stop the discovery before the timeout.
    open func stop() {
        if self.socket != nil {
            Log.info("Stop SSDP discovery")
            self.queueForceStop() { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.delegate?.ssdpDiscoveryDidFinish(strongSelf)
            }
        }
    }
    
    let serialQueue = DispatchQueue(label: "ssdp.forcestop.serial.queue")
    open func queueForceStop(completion: @escaping () -> Void) {
        serialQueue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.forceStop()
            completion()
        }
    }
}
