import Foundation

// F5: a transport play while an audio-session interruption is active.
//
// On the renderer paths (software and audio hosts) the system stops the audio clock itself when an
// interruption begins, and starts nothing again when it ends: resuming is the app's policy
// (`shouldResume`). A `play()` or `setRate(>0)` that arrives in between is not neutral, it restarts
// audio under whatever interrupted the session. AVPlayer does not do that. Its play press during an
// interruption waits for the interruption to end, so the renderer paths hold the press the same way
// and run it when the interruption ends. The native AVPlayer path owns this itself and is untouched.
extension AetherEngine {

    /// Pure decision: whether a play press is held back. Only a renderer path while interrupted.
    nonisolated static func interruptionHoldsTransport(interrupted: Bool, rendererPath: Bool) -> Bool {
        interrupted && rendererPath
    }

    /// Called from `play()`. True when the press was held (the caller returns). The press is
    /// remembered and runs when the interruption ends, whether or not the system grants `shouldResume`,
    /// because the user asked for it.
    func deferPlayForInterruption() -> Bool {
        guard Self.interruptionHoldsTransport(
            interrupted: audioInterruptionActive, rendererPath: softwareHost != nil || audioHost != nil
        ) else { return false }
        playDeferredByInterruption = true
        EngineLog.emit("[AetherEngine] play() held: an audio interruption is active; it runs when the interruption ends", category: .engine)
        return true
    }

    func noteAudioInterruptionBegan() {
        audioInterruptionActive = true
    }

    /// The interruption ended. Returns whether a play press was held meanwhile (and clears it).
    /// The flag is cleared first so the resume that follows is not held by its own guard.
    func noteAudioInterruptionEnded() -> Bool {
        audioInterruptionActive = false
        let deferred = playDeferredByInterruption
        playDeferredByInterruption = false
        return deferred
    }
}
