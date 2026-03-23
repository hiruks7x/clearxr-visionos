import SwiftUI
import Network
#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

struct ConfigurationView: View {
#if !targetEnvironment(simulator)
    @Environment(FoveatedStreamingSession.self) private var session
    @Environment(MessageChannelModel.self) private var messageChannelModel
    private let configManager = ServerConfigurationManager()
#endif

    @Environment(StreamActions.self) private var streamActions

    @AppStorage("configPresetChoice") private var presetChoiceRawValue: String = ConfigurationPresetChoice.defaultChoice.rawValue
    @AppStorage("configRenderedResolution") private var renderedResolution: Int = ResolutionPreset.balanced.renderedResolution
    @AppStorage("configEncodedResolution") private var encodedResolution: Int = ResolutionPreset.balanced.encodedResolution
    @AppStorage("configFoveationInsetPercent") private var foveationInsetPercent: Int = Int(ResolutionPreset.balanced.foveationInsetRatio * 100)
    @AppStorage("configClearXRDefaultAppEnabled") private var clearXRDefaultAppEnabled: Bool = true
    @AppStorage("configAlphaTransparencyEnabled") private var alphaTransparencyEnabled: Bool = false

    @AppStorage("selectedEndpointHost") private var selectedEndpointHost: String = ""
    @AppStorage("selectedEndpointPort") private var selectedEndpointPort: Int = 55000
    @AppStorage("lastConnectionMode") private var lastConnectionMode: String = "manual"

    @State private var isApplying = false
    @State private var isShowingApplyError = false
    @State private var applyErrorMessage: String?
    @State private var applySucceeded = false
    @State private var adjustmentWarning: String?
    @State private var isAutoAdjusting = false
    @State private var restartCountdown: Int?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Preset", selection: selectedPresetBinding) {
                    ForEach(ConfigurationPresetChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Rendered Width")
                        Spacer()
                        Text("\(renderedResolution)")
                            .fontWeight(.semibold)
                    }
                    Slider(value: renderedWidthBinding, in: 4000...8000, step: 16)
                        .disabled(!isCustomPreset)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Encoded Width")
                        Spacer()
                        Text("\(encodedResolution)")
                            .fontWeight(.semibold)
                    }
                    Slider(value: encodedWidthBinding, in: 608...8000, step: 16)
                        .disabled(!isCustomPreset)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Foveation Inset")
                        Spacer()
                        Text("\(foveationInsetPercent)%")
                            .fontWeight(.semibold)
                    }
                    Slider(value: foveationInsetBinding, in: 15...100, step: 5)
                        .disabled(!isCustomPreset)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Clear XR default app", isOn: $clearXRDefaultAppEnabled)
                    Toggle("Enable alpha transparency", isOn: $alphaTransparencyEnabled)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                if let adjustmentWarning {
                    Text(adjustmentWarning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let endpointDescription {
                    Text("Target endpoint: \(endpointDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Target endpoint unavailable. Connect manually or set bonjour host/port.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await applyConfiguration() }
                } label: {
                    Text(isApplying ? "Applying..." : "Apply Configuration")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)

                Text(restartStatusMessage)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .font(.caption2)
                    .foregroundStyle(restartCountdown != nil || applySucceeded ? .green : .secondary)
            }
            .navigationTitle("Configuration")
            .padding()
            .onAppear {
                applySucceeded = false
                normalizeStoredState()
            }
            .onChange(of: renderedResolution) {
                guard isCustomPreset, !isAutoAdjusting else { return }
                updateEncodedFromRendered()
            }
            .onChange(of: encodedResolution) {
                guard isCustomPreset, !isAutoAdjusting else { return }
                updateRenderedFromEncoded()
            }
            .onChange(of: foveationInsetPercent) {
                guard !isAutoAdjusting else { return }
                updateEncodedFromRendered()
            }
            .alert("Failed to apply configuration", isPresented: $isShowingApplyError) {
                Button("OK") { }
            } message: {
                Text(applyErrorMessage ?? "Unknown error")
            }
        }
    }

    private var selectedPresetBinding: Binding<ConfigurationPresetChoice> {
        Binding {
            ConfigurationPresetChoice(rawValue: presetChoiceRawValue) ?? .defaultChoice
        } set: { newValue in
            presetChoiceRawValue = newValue.rawValue
            if let preset = newValue.preset {
                applyPreset(preset)
            }
        }
    }

    private var renderedWidthBinding: Binding<Double> {
        Binding {
            Double(renderedResolution)
        } set: { newValue in
            renderedResolution = Int(newValue)
        }
    }

    private var encodedWidthBinding: Binding<Double> {
        Binding {
            Double(encodedResolution)
        } set: { newValue in
            encodedResolution = Int(newValue)
        }
    }

    private var foveationInsetBinding: Binding<Double> {
        Binding {
            Double(foveationInsetPercent)
        } set: { newValue in
            foveationInsetPercent = Int(newValue)
        }
    }

    private var isCustomPreset: Bool {
        (ConfigurationPresetChoice(rawValue: presetChoiceRawValue) ?? .defaultChoice) == .custom
    }

    private var isSessionConnected: Bool {
#if targetEnvironment(simulator)
        true
#else
        session.status == .connected
#endif
    }

    private var validationError: String? {
        guard renderedResolution > 0, encodedResolution > 0 else {
            return "Resolutions must be greater than zero."
        }
        guard renderedResolution % 16 == 0, encodedResolution % 16 == 0 else {
            return "Rendered and encoded widths must be divisible by 16."
        }
        return nil
    }

    private var canApply: Bool {
        !isApplying && restartCountdown == nil && validationError == nil && isSessionConnected
    }

    private var endpointDescription: String? {
        guard let endpoint = resolvedEndpoint else { return nil }
        return "\(endpoint.host):\(endpoint.port)"
    }

    private var resolvedEndpoint: (host: String, port: Int)? {

        return (selectedEndpointHost, selectedEndpointPort)
    }

    private var payload: StreamConfigurationMessage {
        #if targetEnvironment(simulator)
        let sessionID = "simulator-session"
        #else
        let sessionID = String(describing: ObjectIdentifier(session))
        #endif

        return StreamConfigurationMessage(
            RenderedResolution: renderedResolution,
            EncodedResolution: encodedResolution,
            FoveationInsetRatio: Double(foveationInsetPercent) / 100.0,
            DefaultAppEnabled: clearXRDefaultAppEnabled,
            AlphaTransparencyEnabled: alphaTransparencyEnabled
        )
    }

    private func normalizeStoredState() {
        guard let selectedChoice = ConfigurationPresetChoice(rawValue: presetChoiceRawValue) else {
            presetChoiceRawValue = ConfigurationPresetChoice.defaultChoice.rawValue
            applyPreset(.balanced)
            return
        }

        if selectedChoice == .custom {
            updateEncodedFromRendered()
        } else {
            adjustmentWarning = nil
        }
    }

    private func applyPreset(_ preset: ResolutionPreset) {
        isAutoAdjusting = true
        renderedResolution = preset.renderedResolution
        foveationInsetPercent = Int(preset.foveationInsetRatio * 100)
        encodedResolution = preset.encodedResolution
        isAutoAdjusting = false
        adjustmentWarning = nil
    }

    private func roundTo16(_ value: Int, min minVal: Int, max maxVal: Int) -> Int {
        let rounded = ((value + 8) / 16) * 16
        return max(minVal, min(maxVal, rounded))
    }

    /// Rendered width or foveation inset changed — update encoded width only.
    private func updateEncodedFromRendered() {
        isAutoAdjusting = true
        let raw = Double(renderedResolution) * Double(foveationInsetPercent) / 100.0
        encodedResolution = roundTo16(Int(raw.rounded()), min: 608, max: 8000)
        isAutoAdjusting = false
        adjustmentWarning = nil
    }

    /// Encoded width changed — update rendered width only.
    private func updateRenderedFromEncoded() {
        guard foveationInsetPercent > 0 else { return }
        isAutoAdjusting = true
        let raw = Double(encodedResolution) * 100.0 / Double(foveationInsetPercent)
        renderedResolution = roundTo16(Int(raw.rounded()), min: 4000, max: 8000)
        isAutoAdjusting = false
        adjustmentWarning = nil
    }

    private var restartStatusMessage: String {
        if let countdown = restartCountdown {
            return countdown > 0 ? "Restarting session in \(countdown)..." : "Restarting session..."
        } else if applySucceeded {
            return "Configuration sent."
        } else {
            return "Applies on next session restart"
        }
    }

    private func applyConfiguration() async {
#if targetEnvironment(simulator)
        applySucceeded = true
        startRestartCountdown()
        return
#else
        guard validationError == nil else { return }		

        isApplying = true
        applySucceeded = false
        defer {
            isApplying = false
        }

        do {
            try configManager.sendConfiguration(payload, via: messageChannelModel)
            applySucceeded = true
            startRestartCountdown()
        } catch {
            applyErrorMessage = error.localizedDescription
            isShowingApplyError = true
        }
#endif
    }

    private func startRestartCountdown() {
        restartCountdown = 3
        Task {
            for i in stride(from: 3, through: 1, by: -1) {
                restartCountdown = i
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    restartCountdown = nil
                    return
                }
            }
            restartCountdown = 0

            // Disconnect the current session.
            try? await streamActions.disconnect()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            // Reconnect with the same endpoint.
            do {
                if lastConnectionMode == "manual",
                   let ipAddr = IPv4Address(selectedEndpointHost),
                   let nwPort = NWEndpoint.Port(String(selectedEndpointPort)) {
                    try await streamActions.connect(.local(ipAddress: ipAddr, port: nwPort))
                } else {
                    try await streamActions.connect(.systemDiscovered)
                }
            } catch {
                print("[ServerConfig] Reconnection failed: \(error)")
            }

            restartCountdown = nil
        }
    }
}

#Preview(windowStyle: .automatic, traits: .fixedLayout(width: 580, height: 860)) {
    ConfigurationView()
}
