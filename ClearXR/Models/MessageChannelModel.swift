/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An observable model that maintains message channel state.
*/

#if !targetEnvironment(simulator)
import SwiftUI
import FoveatedStreaming

@MainActor
@Observable
class MessageChannelModel {
    let session: FoveatedStreamingSession
    var availableChannels: [FoveatedStreamingSession.MessageChannel.ID: FoveatedStreamingSession.MessageChannel] = [:]
    var selectedChannelId: FoveatedStreamingSession.MessageChannel.ID? = nil
    
    var selectedChannel: FoveatedStreamingSession.MessageChannel? {
        if let selectedChannelId {
            availableChannels[selectedChannelId]
        } else {
            nil
        }
    }
    
    init(session: FoveatedStreamingSession) {
        self.session = session
        // Listen for changes to the available message channels.
        monitorAvailableChannels()
    }
    
    private func monitorAvailableChannels() {
        withObservationTracking {
            let currentIds = Set(session.availableMessageChannels)

            for channelId in currentIds {
                setUpMessageChannel(for: channelId)
            }
        } onChange: {
            Task { @MainActor in
                self.monitorAvailableChannels()
            }
        }
    }

    /// Re-scan the session for channels not yet in `availableChannels`.
    /// Call this from a polling loop when no ready channel can be found,
    /// as the one-shot `withObservationTracking` may miss channels that
    /// appear after a session restart.
    func refreshChannels() {
        let currentIds = session.availableMessageChannels
        // Only prune when connected; paused sessions stop advertising
        // channels but they return on resume.
        if session.status == .connected {
            for existingId in availableChannels.keys where !currentIds.contains(existingId) {
                availableChannels.removeValue(forKey: existingId)
                if selectedChannelId == existingId {
                    selectedChannelId = nil
                }
            }
        }
        // Set up any new ones.
        for channelId in currentIds {
            setUpMessageChannel(for: channelId)
        }
    }

    private func setUpMessageChannel(for channelId: FoveatedStreamingSession.MessageChannel.ID) {
        // If we already have this channel and it's still the same object, skip.
        if let existing = availableChannels[channelId],
           let fresh = session.messageChannel(for: channelId),
           existing === fresh {
            return
        }

        guard let messageChannel = session.messageChannel(for: channelId) else {
            print("[MessageChannel] Channel \(channelId) listed but not yet available")
            return
        }
        // Save (or replace) the channel.
        print("[MessageChannel] Set up channel \(channelId) (status: \(messageChannel.channelStatus))")
        availableChannels[channelId] = messageChannel
    }
}
#endif
