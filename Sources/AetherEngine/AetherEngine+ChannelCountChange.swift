import AVFoundation
import Foundation

// F4: follow a change of the route's output channel count.
//
// The channel preference of a renderer path is written once, at activation, as
// `min(source channels, maximum the route can output)`. A route that changes mid-play (a 7.1
// receiver switching off for the 2.0 TV speakers, or back) leaves that number describing a route
// that is gone. AVPlayer re-evaluates its configuration on a route change; the renderer paths do
// the equivalent through the public session: on every route change the preference is recomputed
// against the new maximum and rewritten when it differs.
//
// What is deliberately not done: re-decoding or re-feeding in a new layout. The renderer takes the
// PCM layout the engine decoded and the system adapts it to the route (the sources this matters to
// are forward-only and cannot be re-fed, the same reason the automatic-flush handler leaves a gap
// rather than rewinding). The renderer's own output-configuration notification is deprecated in
// favour of the enqueue result and is not used.
// iOS and tvOS only: macOS has no audio session to carry a channel preference.

/// Pure: the channel count a renderer path asks the session for.
nonisolated func preferredOutputChannels(sourceChannels: Int?, maxOutput: Int) -> Int {
    min(sourceChannels ?? maxOutput, maxOutput)
}

extension AetherEngine {

    /// Whether the written preference no longer matches what the route can do.
    nonisolated static func channelPreferenceNeedsRefresh(preferredNow: Int, sourceChannels: Int?, maxOutput: Int) -> Bool {
        preferredNow != preferredOutputChannels(sourceChannels: sourceChannels, maxOutput: maxOutput)
    }

    /// The reaction, with the session reads and the write injected so it runs without a session.
    /// Only a renderer path owns its channel preference. Returns whether a new value was written.
    @discardableResult
    func refreshChannelPreference(
        sourceChannels: Int?, maxOutput: Int, preferredNow: Int, apply: (Int) -> Void
    ) -> Bool {
        guard softwareHost != nil || audioHost != nil else { return false }
        guard Self.channelPreferenceNeedsRefresh(preferredNow: preferredNow, sourceChannels: sourceChannels, maxOutput: maxOutput) else {
            return false
        }
        let wanted = preferredOutputChannels(sourceChannels: sourceChannels, maxOutput: maxOutput)
        EngineLog.emit("[AetherEngine] route change: channel preference \(preferredNow) -> \(wanted) (source=\(sourceChannels?.formatted() ?? "unknown") max=\(maxOutput))", category: .engine)
        apply(wanted)
        return true
    }

    #if os(iOS) || os(tvOS)
    func installChannelCountChangeObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let session = AVAudioSession.sharedInstance()
                let sources = SharedOutputCoordinator.shared.preferredSourceChannels
                self.refreshChannelPreference(
                    sourceChannels: sources,
                    maxOutput: session.maximumOutputNumberOfChannels,
                    preferredNow: session.preferredOutputNumberOfChannels
                ) { wanted in
                    _ = self.enqueueAudioSessionTransition {
                        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(wanted)
                    }
                }
            }
        }
        retainLifecycleObserver(observer)
    }
    #endif
}
