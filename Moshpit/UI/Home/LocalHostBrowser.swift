import Foundation
import Observation

/// Bonjour only: discovery is explicit and never probes arbitrary LAN addresses.
@Observable
final class LocalHostBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Host: Identifiable {
        var id: String { hostname + ":" + String(port) }
        let name: String
        let hostname: String
        let port: Int
    }
    var hosts: [Host] = []
    var failure: String?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    func start() {
        stop(); hosts = []; failure = nil
        browser.delegate = self
        browser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
    }
    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName, sender.port > 0 else { return }
        let host = Host(name: sender.name, hostname: hostname, port: sender.port)
        if !hosts.contains(where: { $0.id == host.id }) { hosts.append(host) }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        failure = "无法发现设备，请检查本地网络权限和 Wi-Fi 连接。"
    }
}
