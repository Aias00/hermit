import Foundation

/// A remote-reported command, never a guess based on output becoming quiet.
/// No command line, arguments or terminal title are retained.
struct ShellCommandObservation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case running, finished }
    var phase: Phase
    var startedAt: Date
    var finishedAt: Date?
    var exitCode: Int?

    var observedAt: Date { finishedAt ?? startedAt }
}

/// Observes the ORIGINAL plain SSH byte stream, before rendering or scrollback
/// replay. Supports FinalTerm OSC 133 and VS Code OSC 633 lifecycle markers,
/// plus OSC 7 / 633 Cwd / 1337 CurrentDir directory reports. It never injects a
/// shell script or interprets a command as something the client should execute.
///
/// Protocol references:
/// https://iterm2.com/documentation-escape-codes.html#shell-integration-finalterm
/// https://code.visualstudio.com/docs/terminal/shell-integration#_supported-escape-sequences
struct ShellIntegrationTracker {
    private enum ParseState { case ground, escape, osc, oscEscape, discard, discardEscape }
    private var state: ParseState = .ground
    private var payload: [UInt8] = []
    private var overflow = false
    private let payloadLimit = 4_096

    private(set) var command: ShellCommandObservation?
    private(set) var workingDirectory: String?

    mutating func feed(_ data: Data, now: Date = Date()) {
        for byte in data {
            // CAN / SUB cancel an incomplete control sequence.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                payload.removeAll(keepingCapacity: true)
                overflow = false
                continue
            }
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                switch byte {
                case 0x5D: // OSC
                    payload.removeAll(keepingCapacity: true)
                    overflow = false
                    state = .osc
                case 0x50, 0x5F, 0x5E, 0x58: // DCS / APC / PM / SOS
                    state = .discard
                case 0x1B:
                    break
                default:
                    state = .ground
                }
            case .osc:
                if byte == 0x07 {
                    finishOSC(now: now)
                } else if byte == 0x1B {
                    state = .oscEscape
                } else if !overflow {
                    if payload.count < payloadLimit { payload.append(byte) }
                    else { payload.removeAll(keepingCapacity: true); overflow = true }
                }
            case .oscEscape:
                if byte == 0x5C { finishOSC(now: now) }
                else {
                    // An embedded escape invalidates the OSC. Stay inside it
                    // through its terminator, so nested lookalikes cannot fire.
                    overflow = true
                    payload.removeAll(keepingCapacity: true)
                    if byte == 0x07 { finishOSC(now: now) }
                    else { state = byte == 0x1B ? .oscEscape : .osc }
                }
            case .discard:
                if byte == 0x1B { state = .discardEscape }
            case .discardEscape:
                // DCS/APC payloads can contain OSC-looking text. Only ST ends
                // them; BEL is data, unlike an OSC terminator.
                if byte == 0x5C { state = .ground }
                else { state = byte == 0x1B ? .discardEscape : .discard }
            }
        }
    }

    private mutating func finishOSC(now: Date) {
        defer {
            payload.removeAll(keepingCapacity: true)
            overflow = false
            state = .ground
        }
        guard !overflow, let text = String(bytes: payload, encoding: .utf8),
              let delimiter = text.firstIndex(of: ";") else { return }
        let code = text[..<delimiter]
        let body = text[text.index(after: delimiter)...]
        switch code {
        case "133", "633":
            if code == "633", body.hasPrefix("P;Cwd=") {
                let value = String(body.dropFirst(6))
                if let decoded = Self.unescapeProperty(value), let path = Self.directory(decoded) {
                    workingDirectory = path
                }
                return
            }
            let fields = body.split(separator: ";", omittingEmptySubsequences: false)
            guard let marker = fields.first else { return }
            switch marker {
            case "A", "B":
                // A prompt without a matching finish makes an in-flight
                // command unknown, NOT successful. Retain an explicit result.
                if command?.phase == .running { command = nil }
            case "C":
                if command?.phase != .running {
                    command = .init(phase: .running, startedAt: now)
                }
            case "D":
                // D after B can mean the user aborted an unexecuted prompt.
                // A finish arriving after reconnect also has no known start.
                guard command?.phase == .running else { return }
                let exitCode: Int?
                if fields.count == 1 || (fields.count == 2 && fields[1].isEmpty) {
                    exitCode = nil
                } else {
                    guard fields.count == 2,
                          let parsed = Self.exitStatus(fields[1], finalTerm: code == "133") else { return }
                    exitCode = parsed
                }
                command?.phase = .finished
                command?.finishedAt = now
                command?.exitCode = exitCode
            default:
                // In particular, E carries a private command line. Ignore it.
                break
            }
        case "7":
            guard let url = URLComponents(string: String(body)), url.scheme == "file",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  let decodedPath = url.percentEncodedPath.removingPercentEncoding,
                  let path = Self.directory(decodedPath) else { return }
            workingDirectory = path
        case "1337":
            guard body.hasPrefix("CurrentDir="),
                  let path = Self.directory(String(body.dropFirst(11))) else { return }
            workingDirectory = path
        default:
            break
        }
    }

    private static func directory(_ value: String) -> String? {
        guard value.hasPrefix("/"), value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private static func exitStatus(_ value: Substring, finalTerm: Bool) -> Int? {
        let digits = value.first == "-" && !finalTerm ? value.dropFirst() : value
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = Int(value) else { return nil }
        if finalTerm { return (0...255).contains(result) ? result : nil }
        return (Int(Int32.min)...Int(UInt32.max)).contains(result) ? result : nil
    }

    /// VS Code properties escape backslashes and ASCII bytes as \\xAB. Decode
    /// strictly once; malformed UTF-8 or escapes cannot become a host path.
    private static func unescapeProperty(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] != 0x5C {
                decoded.append(bytes[index]); index += 1
            } else if index + 1 < bytes.count, bytes[index + 1] == 0x5C {
                decoded.append(0x5C); index += 2
            } else if index + 3 < bytes.count, bytes[index + 1] == 0x78,
                      let high = hex(bytes[index + 2]), let low = hex(bytes[index + 3]) {
                decoded.append(high * 16 + low); index += 4
            } else { return nil }
        }
        return String(bytes: decoded, encoding: .utf8)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
