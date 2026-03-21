/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A framework which makes `FoveatedStreamingSession.Status` and `FoveatedStreamingSession.DisconnectReason` available in the simulator (from the ClearXRSimulator module).
*/

#if targetEnvironment(simulator)
import Foundation
import Network

@MainActor
@Observable
final public class FoveatedStreamingSession: Identifiable {
    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case initialized
        case connecting
        case connected
        case disconnected(FoveatedStreamingSession.DisconnectReason)
        case disconnecting
        case paused
        case pausing
        case resuming

        public var description: String {
            switch self {
            case .initialized:
                "initialized"
            case .connecting:
                "connecting"
            case .connected:
                "connected"
            case .disconnected(let reason):
                "disconnected(\(reason))"
            case .disconnecting:
                "disconnecting"
            case .paused:
                "paused"
            case .pausing:
                "pausing"
            case .resuming:
                "resuming"
            }
        }
    }

    public struct DisconnectReason: LocalizedError, Equatable, Sendable, CustomStringConvertible {
        public static var appInitiatedDisconnect: FoveatedStreamingSession.DisconnectReason { .init(.appInitiatedDisconnect) }
        public static var endpointInitiatedDisconnect: FoveatedStreamingSession.DisconnectReason { .init(.endpointInitiatedDisconnect) }
        public static var unauthorized: FoveatedStreamingSession.DisconnectReason { .init(.unauthorized) }
        public static var unavailable: FoveatedStreamingSession.DisconnectReason { .init(.unavailable) }
        public static var simulatorTestDisconnect: FoveatedStreamingSession.DisconnectReason { .init(.simulatorTestDisconnect) }

        public var errorDescription: String? {
            switch value {
            case .simulatorTestDisconnect:
                "Simulator disconnection test."
            case .appInitiatedDisconnect:
                "Disconnected by app."
            case .endpointInitiatedDisconnect:
                "Disconnected by endpoint."
            case .unauthorized:
                "Unauthorized."
            case .unavailable:
                "Endpoint unavailable."
            }
        }

        public var description: String {
            switch value {
            case .appInitiatedDisconnect:
                "appInitiatedDisconnect"
            case .unauthorized:
                "unauthorized"
            case .endpointInitiatedDisconnect:
                "endpointInitiatedDisconnect"
            case .unavailable:
                "unavailable"
            case .simulatorTestDisconnect:
                "simulatorTestDisconnect"
            }
        }

        private var value: Value

        private init(_ value: Value) {
            self.value = value
        }

        private enum Value {
            case appInitiatedDisconnect
            case unauthorized
            case endpointInitiatedDisconnect
            case unavailable
            case simulatorTestDisconnect
        }
    }

    public struct Endpoint {
        public static var systemDiscovered: Self { .init(.systemDiscovered) }
        public static func local(ipAddress: IPAddress, port: NWEndpoint.Port) -> Self { .init(.local(ipAddress: ipAddress, port: port)) }
        public static func remote(serverName: String, signalingHeaders: [String: String]) -> Self {
            .init(.remote(serverName: serverName, signalingHeaders: signalingHeaders))
        }

        private var value: Value

        private init(_ value: Value) {
            self.value = value
        }

        private enum Value {
            case systemDiscovered
            case local(ipAddress: IPAddress, port: NWEndpoint.Port)
            case remote(serverName: String, signalingHeaders: [String: String])
        }
    }

    public init() {}

    // Status/state exposed to the app.
    @MainActor final public var status: FoveatedStreamingSession.Status = .initialized

    // Simulator controls for development.
    @MainActor final public var simulatedConnectShouldFail = false
    @MainActor final public var simulatedConnectFailureReason: DisconnectReason = .simulatorTestDisconnect
    @MainActor final public var simulatedConnectDelay: Duration = .seconds(1)
    @MainActor final public var simulatedPauseResumeDelay: Duration = .seconds(1)
    @MainActor final public var simulatedDisconnectDelay: Duration = .milliseconds(200)

    @MainActor
    final public func connect(endpoint: Endpoint = .systemDiscovered) async throws {
        _ = endpoint
        status = .connecting
        try await Task.sleep(for: simulatedConnectDelay)

        if Task.isCancelled {
            status = .disconnected(.appInitiatedDisconnect)
            throw CancellationError()
        }

        if simulatedConnectShouldFail {
            status = .disconnected(simulatedConnectFailureReason)
            throw simulatedConnectFailureReason
        }

        status = .connected
    }

    @MainActor
    final public func pause() async throws {
        guard status == .connected else { return }
        status = .pausing
        try await Task.sleep(for: simulatedPauseResumeDelay)

        if Task.isCancelled {
            status = .connected
            throw CancellationError()
        }

        status = .paused
    }

    @MainActor
    final public func resume() async throws {
        guard status == .paused else { return }
        status = .resuming
        try await Task.sleep(for: simulatedPauseResumeDelay)

        if Task.isCancelled {
            status = .paused
            throw CancellationError()
        }

        status = .connected
    }

    @MainActor
    final public func disconnect() async {
        switch status {
        case .initialized, .disconnected:
            status = .disconnected(.appInitiatedDisconnect)
            return
        default:
            status = .disconnecting
            try? await Task.sleep(for: simulatedDisconnectDelay)
            status = .disconnected(.appInitiatedDisconnect)
        }
    }
}
#endif
