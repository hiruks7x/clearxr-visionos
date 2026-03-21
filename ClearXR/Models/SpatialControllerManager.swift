/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An observable model that reads PSVR2 Sense spatial controller input via the
GameController framework and sends binary packets over a FoveatedStreaming
message channel. Each hand is a separate GCController instance; handedness
is determined by chirality-prefixed element names in the physical input profile.
*/

import SwiftUI
import CoreHaptics
import RealityKit

#if !targetEnvironment(simulator)
import GameController
import FoveatedStreaming

/// A RealityKit System that polls spatial controllers every frame,
/// synchronized to the headset's display refresh rate.
class SpatialControllerSystem: System {
    static var manager: SpatialControllerManager?

    required init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        if Thread.isMainThread {
            Self.manager?.pollAndSend()
            Self.manager?.processHapticMessages()
        } else {
            Task { @MainActor in
                Self.manager?.pollAndSend()
                Self.manager?.processHapticMessages()
            }
        }
    }
}

@MainActor
@Observable
class SpatialControllerManager {
    let messageChannelModel: MessageChannelModel

    private(set) var leftController: GCController?
    private(set) var rightController: GCController?
    private(set) var isSending = false
    private(set) var leftControllerName: String?
    private(set) var rightControllerName: String?
    private(set) var packetsSent: UInt64 = 0

    private var receiveTask: Task<Void, Never>?
    private var connectObserver: Any?
    private var disconnectObserver: Any?
    private var lastChannelNotReadyLog: ContinuousClock.Instant?

    // Haptic engines — lazily created per controller.
    private var leftEngine: CHHapticEngine?
    private var rightEngine: CHHapticEngine?
    private var receivingChannelId: FoveatedStreamingSession.MessageChannel.ID?

    /// Buffer for haptic messages drained from the async stream,
    /// processed each frame by the RealityKit system.
    private var pendingHapticMessages: [Data] = []

    init(messageChannelModel: MessageChannelModel) {
        self.messageChannelModel = messageChannelModel
    }

    func startMonitoring() {
        guard !isSending else { return }
        observeControllerNotifications()
        // Pick up any already-connected controllers.
        for controller in GCController.controllers() {
            didConnect(controller)
        }
        isSending = true
        SpatialControllerSystem.manager = self
    }

    func stopMonitoring() {
        guard isSending else { return }
        SpatialControllerSystem.manager = nil
        isSending = false
        stopReceiving()
        removeControllerNotifications()
        leftController = nil
        rightController = nil
        leftControllerName = nil
        rightControllerName = nil
        tearDownHapticEngines()
    }

    // MARK: - Handedness detection

    enum ControllerHand {
        case left, right
    }

    /// Determines handedness by inspecting chirality-prefixed element names.
    /// Spatial controllers expose elements like "Left Trigger", "Right Button A", etc.
    private func identifyHand(for controller: GCController) -> ControllerHand? {
        if controller.vendorName?.contains("(L)") ?? false {return .left}
        else if controller.vendorName?.contains("(R)") ?? false {return .right}
        else {
            return nil
        }
    }

    // MARK: - Controller notifications

    private func observeControllerNotifications() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let controller = notification.object as? GCController else { return }
            Task { @MainActor in self.didConnect(controller) }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let controller = notification.object as? GCController else { return }
            Task { @MainActor in self.didDisconnect(controller) }
        }
    }

    private func removeControllerNotifications() {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        connectObserver = nil
        disconnectObserver = nil
    }

    private func didConnect(_ controller: GCController) {
        let name = controller.vendorName ?? "Controller"

        guard let hand = identifyHand(for: controller) else {
            // Log available elements for debugging unknown controllers.
            let profile = controller.physicalInputProfile
            let allNames = Array(profile.buttons.keys) +
                           Array(profile.dpads.keys) +
                           Array(profile.axes.keys)
            print("[SpatialController] Unknown handedness for \(name). Elements: \(allNames)")
            return
        }

        switch hand {
        case .left:
            guard leftController == nil else { return }
            leftController = controller
            leftControllerName = "\(name)"
            prewarmHapticEngine(for: .left)
            print("[SpatialController] Left controller connected: \(name)")
        case .right:
            guard rightController == nil else { return }
            rightController = controller
            rightControllerName = "\(name)"
            prewarmHapticEngine(for: .right)
            print("[SpatialController] Right controller connected: \(name)")
        }
    }

    private func didDisconnect(_ controller: GCController) {
        if controller === leftController {
            leftController = nil
            leftControllerName = nil
            leftEngine?.stop()
            leftEngine = nil
            print("[SpatialController] Left controller disconnected")
        } else if controller === rightController {
            rightController = nil
            rightControllerName = nil
            rightEngine?.stop()
            rightEngine = nil
            print("[SpatialController] Right controller disconnected")
        }
    }

    // MARK: - Per-frame polling (called by SpatialControllerSystem)

    func pollAndSend() {
        guard messageChannelModel.session.status == .connected else { return }
        guard leftController != nil || rightController != nil else { return }

        var channel = messageChannelModel.availableChannels.values.first(where: {
            $0.channelStatus == .ready
        })

        if channel == nil {
            // The observation-based monitor may have missed a new channel
            // after a session restart. Poll the session directly.
            messageChannelModel.refreshChannels()
            channel = messageChannelModel.availableChannels.values.first(where: {
                $0.channelStatus == .ready
            })
        }

        guard let channel else {
            let now = ContinuousClock.now
            if lastChannelNotReadyLog == nil || now - lastChannelNotReadyLog! > .seconds(2) {
                print("[SpatialController] Channel not ready for sending (\(messageChannelModel.availableChannels.count) channels cached, \(messageChannelModel.session.availableMessageChannels.count) in session)")
                lastChannelNotReadyLog = now
            }
            return
        }

        var packet = SpatialControllerPacket()

        if let left = leftController {
            packet.activeHands |= SpatialControllerPacket.ActiveHands.left
            packet.left = readHandState(from: left, hand: .left)
        }
        if let right = rightController {
            packet.activeHands |= SpatialControllerPacket.ActiveHands.right
            packet.right = readHandState(from: right, hand: .right)
        }

        // Start receiving haptic packets from this channel if we haven't already.
        startReceiving(on: channel)

        do {
            try channel.sendMessage(packet.serialize())
            packetsSent += 1
            if packetsSent == 1 {  print("[SpatialController] Sent first packet")}
        } catch {
            // Transient send failures expected; don't kill the loop.
        }
    }

    /// Reads button, stick, and trigger state from a single spatial controller.
    ///
    /// PSVR2 Sense controllers expose chirality-prefixed elements:
    /// - "Left/Right Button A" (Triangle/Circle), "Left/Right Button B" (Square/Cross)
    /// - "Left/Right Trigger", "Left/Right Grip" (grip)
    /// - "Left/Right Thumbstick", "Left/Right Thumbstick Button"
    /// - "Menu Button"
    ///
    /// Falls back to generic GCInput names for non-PSVR2 spatial controllers.
    private func readHandState(from controller: GCController, hand: ControllerHand) -> SpatialControllerPacket.HandState {
        var state = SpatialControllerPacket.HandState()
        guard let input = controller.input.nextInputState() else {
            return state
        }
    
        if input.buttons["Button A"]?.pressedInput.isPressed  ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.buttonA }
        if input.buttons["Button A"]?.touchedInput?.isTouched  ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.touchButtonA }
        
        if input.buttons["Button B"]?.pressedInput.isPressed  ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.buttonB }
        if input.buttons["Button B"]?.touchedInput?.isTouched  ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.touchButtonB }

        if input.buttons["Thumbstick Button"]?.pressedInput.isPressed  ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.thumbstickClick }
        if input.buttons["Thumbstick Button"]?.touchedInput?.isTouched  ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.touchThumbstick }
        
        if input.buttons["Button Menu"]?.pressedInput.isPressed ?? false { state.buttons |= SpatialControllerPacket.ButtonMask.menu }
        
        state.trigger = input.buttons["Trigger"]?.pressedInput.value ?? 0.0
        if input.buttons["Trigger"]?.pressedInput.isPressed == true { state.buttons |= SpatialControllerPacket.ButtonMask.trigger }
        if input.buttons["Trigger"]?.touchedInput?.isTouched == true { state.buttons |= SpatialControllerPacket.ButtonMask.touchTrigger }
        
        state.grip = input.buttons["Grip"]?.pressedInput.value ?? 0.0
        if input.buttons["Grip"]?.pressedInput.isPressed == true { state.buttons |= SpatialControllerPacket.ButtonMask.grip }
        if input.buttons["Grip"]?.touchedInput?.isTouched == true { state.buttons |= SpatialControllerPacket.ButtonMask.touchGrip }

        return state
    }

    // MARK: - Haptic Receive

    /// Starts an async task that drains incoming haptic messages into
    /// `pendingHapticMessages`. The buffer is processed each frame by
    /// `processHapticMessages()`, called from the RealityKit system.
    private func startReceiving(on channel: FoveatedStreamingSession.MessageChannel) {
        // Already receiving on this channel.
        if receivingChannelId == channel.id { return }
        stopReceiving()
        receivingChannelId = channel.id
        print("[SpatialController] Starting haptic receive on channel \(channel.id)")
        receiveTask = Task { @MainActor [weak self] in
            for await message in channel.receivedMessageStream {
                guard !Task.isCancelled else { break }
                self?.pendingHapticMessages.append(message)
            }
            // Stream ended (channel closed / session restarted).
            self?.receivingChannelId = nil
            print("[SpatialController] Haptic receive stream ended")
        }
    }

    private func stopReceiving() {
        receiveTask?.cancel()
        receiveTask = nil
        receivingChannelId = nil
        pendingHapticMessages.removeAll()
    }

    /// Processes all buffered haptic messages. Called once per frame
    /// by `SpatialControllerSystem.update(context:)`.
    func processHapticMessages() {
        guard !pendingHapticMessages.isEmpty else { return }
        for data in pendingHapticMessages {
            // Log raw data for troubleshooting; skip actual playback for now.
            guard let haptic = HapticEventPacket.deserialize(from: data) else {
                print("[SpatialController] Haptic: failed to deserialize \(data.count) bytes")
                continue
            }
            let hand = haptic.isLeft ? "left" : "right"
            print("[SpatialController] Haptic: hand=\(hand) amp=\(haptic.amplitude) freq=\(haptic.frequency) dur=\(haptic.durationSeconds)s")
            if haptic.isLeft, let controller = leftController {
                playHaptic(haptic, on: controller, hand: .left)
            } else if !haptic.isLeft, let controller = rightController {
                playHaptic(haptic, on: controller, hand: .right)
            }
        }
        pendingHapticMessages.removeAll()
    }

    // MARK: - Haptic Engine Management

    private func prewarmHapticEngine(for hand: ControllerHand) {
        switch hand {
        case .left:
            guard leftEngine == nil, let controller = leftController else { return }
            leftEngine = createEngine(for: controller, label: "left")
        case .right:
            guard rightEngine == nil, let controller = rightController else { return }
            rightEngine = createEngine(for: controller, label: "right")
        }
    }

    private func createEngine(for controller: GCController, label: String) -> CHHapticEngine? {
        guard let haptics = controller.haptics else {
            print("[SpatialController] No haptics support on \(label) controller")
            return nil
        }

        // Try the specific handle locality first, then fall back.
        let preferredLocality: GCHapticsLocality = label == "left" ? .leftHandle : .rightHandle
        var engine = haptics.createEngine(withLocality: preferredLocality)

        if engine == nil {
            // Fall back to chirality-matching locality from supported list.
            let suffix = label == "left" ? "(L)" : "(R)"
            for locality in haptics.supportedLocalities {
                if (locality.rawValue as String).contains(suffix) {
                    engine = haptics.createEngine(withLocality: locality)
                    break
                }
            }
        }

        if engine == nil {
            engine = haptics.createEngine(withLocality: .all)
        }

        if let engine {
            do {
                try engine.start()
                print("[SpatialController] Haptic engine started for \(label)")
            } catch {
                print("[SpatialController] Error starting \(label) haptic engine: \(error)")
                return nil
            }
        }
        return engine
    }

    private func playHaptic(
        _ haptic: HapticEventPacket,
        on controller: GCController,
        hand: ControllerHand
    ) {
        let label = hand == .left ? "left" : "right"

        var engine: CHHapticEngine?
        if hand == .left {
            if leftEngine == nil {
                leftEngine = createEngine(for: controller, label: label)
            }
            engine = leftEngine
        } else {
            if rightEngine == nil {
                rightEngine = createEngine(for: controller, label: label)
            }
            engine = rightEngine
        }

        guard let engine else { return }

        // Clamp duration: min 32ms (PSVR2 floor), max 500ms.
        let duration = min(max(haptic.durationSeconds, 0.032), 0.5)

        // Scale amplitude for PSVR2 Sense controllers.
        let amplitude = min(max(haptic.amplitude * 0.25, 0.0), 1.0)

        guard amplitude > 0 else { return }

        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: amplitude)
                ], relativeTime: 0, duration: duration)
            ], parameters: [])

            try engine.makePlayer(with: pattern).start(atTime: engine.currentTime)
        } catch {
            print("[SpatialController] Error playing \(label) haptic: \(error)")
            engine.stop()
            if hand == .left {
                leftEngine = nil
            } else {
                rightEngine = nil
            }
        }
    }

    private func tearDownHapticEngines() {
        leftEngine?.stop()
        leftEngine = nil
        rightEngine?.stop()
        rightEngine = nil
    }

}

#else

// Simulator stub — same observable surface, no-ops.
@MainActor
@Observable
class SpatialControllerManager {
    private(set) var leftController: AnyObject? = nil
    private(set) var rightController: AnyObject? = nil
    private(set) var isSending = false
    private(set) var leftControllerName: String?
    private(set) var rightControllerName: String?
    private(set) var packetsSent: UInt64 = 0

    func startMonitoring() {}
    func stopMonitoring() {}
}

#endif
