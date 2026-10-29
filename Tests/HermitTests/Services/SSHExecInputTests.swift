import Foundation
import Testing
@testable import Moshpit

@Suite("SSH exec stdin isolation")
struct SSHExecInputTests {
    @Test("Exec forwards stdin bytes separately without changing the command")
    func stdinIsSeparate() async throws {
        let transport = InputTransport()
        let session = SSHSession(connection: ServerConnection(), transport: transport)
        let payload = Data("secret'\n$()\u{0}\u{1b}".utf8)
        let output = try await session.executeCommand("fixed-helper", standardInput: payload)
        #expect(output == Data("accepted".utf8))
        let request = await transport.request
        #expect(request?.0 == "fixed-helper")
        #expect(request?.1 == payload)
        #expect(await transport.ordinaryCalls == 0)
        await session.close()
    }

    @Test("A transport without stdin support fails closed")
    func noArgumentFallback() async {
        let session = SSHSession(connection: ServerConnection(), transport: QuietTransport())
        await #expect(throws: SSHError.self) {
            _ = try await session.executeCommand("fixed-helper", standardInput: Data("secret".utf8))
        }
        await session.close()
    }

    private actor InputTransport: SSHClientTransport {
        var request: (String, Data)?
        var ordinaryCalls = 0
        func run(_ command: String) async throws -> Data {
            ordinaryCalls += 1
            return Data()
        }
        func run(_ command: String, standardInput: Data) async throws -> Data {
            request = (command, standardInput)
            return Data("accepted".utf8)
        }
        func openPTY(rows: Int, cols: Int,
                     onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            throw SSHError.ptyNotReady
        }
        func shutdown() async {}
    }
}
