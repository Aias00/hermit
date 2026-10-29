import Foundation

/// Read-only presentation and search over saved hosts. Filtering never changes
/// the store's order or the sessions retained by SessionHub.
enum HostListPresentation {
    static func filtered(_ connections: [ServerConnection], query: String) -> [ServerConnection] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return connections }
        return connections.filter { host in
            let fields = searchFields(for: host)
            return terms.allSatisfy { term in
                fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }

    static func endpoint(for host: ServerConnection) -> String {
        let address = host.host.contains(":") && !host.host.hasPrefix("[") ? "[\(host.host)]" : host.host
        let destination = host.port == 22 ? address : "\(address):\(host.port)"
        return host.username.isEmpty ? destination : "\(host.username)@\(destination)"
    }

    static func routeLabel(for host: ServerConnection) -> String {
        switch host.transport {
        case .direct: return String(localized: "Direct")
        case .socks5: return "SOCKS5"
        case .cloudflareSSH: return "Cloudflare"
        case .tailcat: return "Tailcat"
        case .tailscale: return "Tailscale"
        case nil: return String(localized: "Unknown transport")
        }
    }

    static func routeSymbol(for host: ServerConnection) -> String {
        switch host.transport {
        case .direct: return "network"
        case .socks5: return "arrow.triangle.branch"
        case .cloudflareSSH: return "cloud"
        case .tailcat, .tailscale: return "point.3.connected.trianglepath.dotted"
        case nil: return "exclamationmark.triangle"
        }
    }

    static func sessionLabel(for host: ServerConnection) -> String {
        host.multiplexer == .none
            ? host.connectionProtocol.label
            : "\(host.connectionProtocol.label) · \(host.multiplexer.label)"
    }

    private static func searchFields(for host: ServerConnection) -> [String] {
        var fields = [host.displayName, host.host, host.username, endpoint(for: host),
                      host.connectionProtocol.label, routeLabel(for: host)]
        if let transport = host.transport {
            fields += [transport.rawValue, transport.label]
        }
        if host.multiplexer != .none { fields.append(host.multiplexer.label) }
        // Only the selected route contributes its public endpoint. Stale route
        // settings and authentication metadata are not searchable host identity.
        if host.transport == .cloudflareSSH, let hostname = host.cloudflareHostname {
            fields.append(hostname)
        }
        return fields
    }
}
