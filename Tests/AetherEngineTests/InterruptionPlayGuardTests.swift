import Testing
@testable import AetherEngine

/// F5: a play press while an audio-session interruption is active must not restart audio on the
/// renderer paths. The notification itself only exists on iOS and tvOS, so the tests drive the same
/// entry points the observer calls.
@Suite("F5: play() during an audio interruption")
@MainActor
struct InterruptionPlayGuardTests {

    private func engine(withSoftwareHost: Bool = true) throws -> AetherEngine {
        let engine = try AetherEngine()
        if withSoftwareHost { engine.softwareHost = SoftwarePlaybackHost(videoGravity: .resizeAspect) }
        engine.state = .paused
        return engine
    }

    @Test("decision: only a renderer path is held, and only while interrupted")
    func decision() {
        #expect(AetherEngine.interruptionHoldsTransport(interrupted: true, rendererPath: true))
        #expect(!AetherEngine.interruptionHoldsTransport(interrupted: true, rendererPath: false))
        #expect(!AetherEngine.interruptionHoldsTransport(interrupted: false, rendererPath: true))
    }

    @Test("play() with no interruption plays")
    func playsNormally() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.play()
        #expect(engine.state == .playing)
        #expect(!engine.playDeferredByInterruption)
    }

    @Test("play() during an interruption is held, state stays paused")
    func playHeld() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        #expect(engine.state == .paused)
        #expect(engine.playDeferredByInterruption)
    }

    @Test("the held play is owed when the interruption ends, once")
    func ownedAtEnd() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        #expect(engine.noteAudioInterruptionEnded())
        #expect(!engine.audioInterruptionActive)
        #expect(!engine.noteAudioInterruptionEnded())
        engine.play()
        #expect(engine.state == .playing, "the guard is gone once the interruption ended")
    }

    @Test("an interruption with no play press owes nothing")
    func nothingOwed() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        #expect(!engine.noteAudioInterruptionEnded())
    }

    @Test("a user pause() cancels the held play")
    func pauseCancels() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.pause()
        #expect(!engine.noteAudioInterruptionEnded())
    }

    @Test("setRate during an interruption is held and does not mark a play press")
    func setRateHeld() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.state = .playing
        engine.noteAudioInterruptionBegan()
        engine.setRate(1.5)
        #expect(engine.desiredRate == 1.5)
        #expect(!engine.playDeferredByInterruption)
        #expect(engine.state == .playing)
    }

    @Test("without a renderer path the engine does not hold play")
    func nativePathUntouched() throws {
        let engine = try engine(withSoftwareHost: false)
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        #expect(!engine.deferPlayForInterruption())
    }

    @Test("stop() clears an interruption that never reported its end")
    func stopClears() throws {
        let engine = try engine()
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.stop()
        #expect(!engine.audioInterruptionActive)
        #expect(!engine.playDeferredByInterruption)
    }
}
