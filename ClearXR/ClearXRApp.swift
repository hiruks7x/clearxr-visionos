/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The SwiftUI `App` structure, which acts as the entry point of the app. Defines the windows and spaces the app uses as well as global state.
*/

import SwiftUI
import RealityKit

#if targetEnvironment(simulator)
import ClearXRSimulator
#else
import FoveatedStreaming
#endif

@main
struct ClearXRApp: App {
    private let session = FoveatedStreamingSession()
    private let appModel = AppModel()

    #if targetEnvironment(simulator)
    private let spatialControllerManager = SpatialControllerManager()
    #else
    private let messageChannelModel: MessageChannelModel
    private let spatialControllerManager: SpatialControllerManager
    #endif

    init() {
        #if !targetEnvironment(simulator)
        messageChannelModel = MessageChannelModel(session: session)
        spatialControllerManager = SpatialControllerManager(messageChannelModel: messageChannelModel)
        SpatialControllerSystem.registerSystem()
        #endif
    }

    var body: some SwiftUI.Scene {
        Window("Main", id: appModel.mainWindowId) {
            ContentView(session: session)
                .environment(appModel)
                .environment(spatialControllerManager)
                #if !targetEnvironment(simulator)
                .environment(messageChannelModel)
                #endif
                .environment(session)
                .environment(
                    StreamActions(
                        connect: { endpoint in
                            try await session.connect(endpoint: endpoint)
                        },
                        pause: {
                            try await session.pause()
                        },
                        resume: {
                            try await session.resume()
                        },
                        disconnect: {
                            await session.disconnect()
                        }
                    )
                )
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        #if !targetEnvironment(simulator)
        ImmersiveSpace(foveatedStreaming: session) {
            SpatialContainer {
                ReopenMainWindowView()
                    .environment(appModel)
            }
            .onDisappear {
                // Digital crown dismissal — pause the stream.
                Task {
                    try? await session.pause()
                }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed, .full)
        .persistentSystemOverlays(.hidden)
        .upperLimbVisibility(.hidden)
        #endif
    }
}
