import Testing
@testable import AetherEngine

/// F4: the renderer paths rewrite their channel preference when the route's maximum changes. The
/// notification exists on iOS and tvOS only; the tests drive the reaction with injected session values.
@Suite("F4: output channel count change")
@MainActor
struct ChannelCountChangeTests {

    private func engine(software: Bool = true) throws -> AetherEngine {
        let engine = try AetherEngine()
        if software { engine.softwareHost = SoftwarePlaybackHost(videoGravity: .resizeAspect) }
        return engine
    }

    @Test("the preference is the source count capped by what the route can output")
    func preferenceMath() {
        #expect(preferredOutputChannels(sourceChannels: 8, maxOutput: 8) == 8)
        #expect(preferredOutputChannels(sourceChannels: 8, maxOutput: 2) == 2)
        #expect(preferredOutputChannels(sourceChannels: 2, maxOutput: 8) == 2)
        #expect(preferredOutputChannels(sourceChannels: nil, maxOutput: 6) == 6)
    }

    @Test("a 7.1 receiver switching to 2.0 speakers lowers the preference")
    func routeDropsToStereo() throws {
        let engine = try engine()
        defer { engine.stop() }
        var written: [Int] = []
        let applied = engine.refreshChannelPreference(sourceChannels: 8, maxOutput: 2, preferredNow: 8) { written.append($0) }
        #expect(applied)
        #expect(written == [2])
    }

    @Test("and raises it again when the receiver returns")
    func routeReturnsToSurround() throws {
        let engine = try engine()
        defer { engine.stop() }
        var written: [Int] = []
        engine.refreshChannelPreference(sourceChannels: 8, maxOutput: 8, preferredNow: 2) { written.append($0) }
        #expect(written == [8])
    }

    @Test("an unchanged preference is not rewritten")
    func unchangedIsLeftAlone() throws {
        let engine = try engine()
        defer { engine.stop() }
        var written: [Int] = []
        let applied = engine.refreshChannelPreference(sourceChannels: 6, maxOutput: 8, preferredNow: 6) { written.append($0) }
        #expect(!applied)
        #expect(written.isEmpty)
    }

    @Test("the native path owns its own channels and is left alone")
    func nativeUntouched() throws {
        let engine = try engine(software: false)
        defer { engine.stop() }
        var written: [Int] = []
        let applied = engine.refreshChannelPreference(sourceChannels: 8, maxOutput: 2, preferredNow: 8) { written.append($0) }
        #expect(!applied)
        #expect(written.isEmpty)
    }
}
