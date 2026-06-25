import Foundation
import Network
import os

enum IRCConfiguration {
    static let server = "irc.tupac.gay"
    static let port: UInt16 = 6667
    static let channel = "#grooveshark"
}

enum IRCError: LocalizedError {
    case invalidPort
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "Invalid IRC port."
        case .notConnected:
            "Not connected to IRC server."
        }
    }
}

actor IRCClient {
    private let host: String
    private let port: UInt16
    private let channel: String
    private let nick: String
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var onLine: (@Sendable (String) -> Void)?

    init(
        host: String = IRCConfiguration.server,
        port: UInt16 = IRCConfiguration.port,
        channel: String = IRCConfiguration.channel,
        nick: String
    ) {
        self.host = host
        self.port = port
        self.channel = channel
        self.nick = nick
    }

    func setOnLine(_ handler: @escaping @Sendable (String) -> Void) {
        onLine = handler
    }

    func connect() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw IRCError.invalidPort
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection

        try await waitForReady(connection)
        startReceiving(on: connection)

        try await sendRaw("NICK \(nick)")
        try await sendRaw("USER \(nick) 0 * :GrooveShark User")
        try await sendRaw("JOIN \(channel)")
    }

    func sendMessage(_ text: String) async throws {
        try await sendRaw("PRIVMSG \(channel) :\(text)")
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    private func waitForReady(_ connection: NWConnection) async throws {
        let resumeLock = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                resumeLock.withLock { resumed in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume()
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        resumed = true
                        continuation.resume(throwing: IRCError.notConnected)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak connection] data, _, isComplete, error in
            guard let connection else { return }
            Task {
                await self.handleReceived(data: data, isComplete: isComplete, error: error, on: connection)
            }
        }
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: NWError?, on connection: NWConnection) {
        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            processBuffer()
        }

        if error != nil || isComplete {
            onLine?("ERROR :Connection closed")
            return
        }

        startReceiving(on: connection)
    }

    private func processBuffer() {
        while let range = receiveBuffer.range(of: Data("\r\n".utf8)) {
            let lineData = receiveBuffer[..<range.lowerBound]
            receiveBuffer.removeSubrange(..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("PING") {
            let payload = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            Task { try? await sendRaw("PONG \(payload)") }
            return
        }
        onLine?(line)
    }

    private func sendRaw(_ line: String) async throws {
        guard let connection else { throw IRCError.notConnected }
        let data = Data("\(line)\r\n".utf8)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
