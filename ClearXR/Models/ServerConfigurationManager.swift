import Foundation
import Network

enum ServerConfigurationError: LocalizedError {
    case invalidPort
    case invalidHost
    case failedToConnect

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "Invalid target port"
        case .invalidHost:
            "Invalid target host"
        case .failedToConnect:
            "Failed to connect to server"
        }
    }
}

@MainActor
final class ServerConfigurationManager {
    private let queue = DispatchQueue(label: "clearxr.config.sender")

    func sendConfiguration(_ payload: StreamConfigurationMessage, host: String, port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(String(port)) else {
            throw ServerConfigurationError.invalidPort
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ServerConfigurationError.invalidHost
        }

        let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: .tcp)

        try await waitUntilReady(connection)

        let payloadData = try JSONEncoder().encode(payload)
        var lengthPrefix = UInt32(payloadData.count).littleEndian
        var frame = Data(bytes: &lengthPrefix, count: MemoryLayout<UInt32>.size)
        frame.append(payloadData)
        print("Configuration change request: \(lengthPrefix) \(String(data: payloadData, encoding: .utf8) ?? "<invalid UTF-8>")" )
  
        try await send(frame, over: connection)
        connection.cancel()
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume(returning: ())
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: ServerConfigurationError.failedToConnect)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}
