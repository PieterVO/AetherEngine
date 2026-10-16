import AVFoundation
import Foundation
import MediaPlayer
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A remote command the system forwards to the engine, already decoded off the MediaPlayer event types.
enum SoftwareNowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    /// Signed: negative skips back.
    case skip(seconds: Double)
    case changePosition(to: Double)
}

/// What the Now-Playing publisher drives and reads. The engine conforms; tests use a recording stand-in.
@MainActor
protocol SoftwareNowPlayingTransport: AnyObject {
    var state: PlaybackState { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var isLive: Bool { get }
    func play()
    func pause()
    func togglePlayPause()
    func seek(to seconds: Double) async
}

extension AetherEngine: SoftwareNowPlayingTransport {}

/// The system side of Now-Playing: an info dictionary plus command registration. Real implementation is
/// `SystemNowPlayingSink`; the controller only sees this, so the state mapping needs no MediaPlayer.
@MainActor
protocol SoftwareNowPlayingSink: AnyObject {
    func activate(handler: @escaping @MainActor (SoftwareNowPlayingCommand) -> Void)
    func setSeekingEnabled(_ enabled: Bool)
    func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState)
    func deactivate()
}

/// Pure mapping from engine state to what the system card shows, and from commands to engine actions.
enum SoftwareNowPlayingPolicy {
    /// Interval for the skip buttons; matches the engine's own skip step on a remote.
    static let skipInterval: Double = 10

    /// A published position the system extrapolates from rate; a clock jump beyond this many seconds from
    /// that extrapolation (a seek while paused, a host-driven reposition) is republished.
    static let driftTolerance: Double = 2

    /// Rate the system extrapolates elapsed with: the requested speed while actually advancing, else 0.
    static func playbackRate(state: PlaybackState, isBuffering: Bool, requestedRate: Float) -> Double {
        guard state == .playing, !isBuffering else { return 0 }
        return Double(requestedRate > 0 ? requestedRate : 1)
    }

    /// `intendedPlaying` carries the last play/pause intent across `.loading`/`.seeking`, which say
    /// nothing about it, so the transport glyph does not flicker through a scrub.
    static func playbackState(state: PlaybackState, intendedPlaying: Bool) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing: return .playing
        case .paused: return .paused
        case .loading, .seeking: return intendedPlaying ? .playing : .paused
        case .ended: return .stopped
        case .idle, .error: return .stopped
        }
    }

    /// Whether the card shows at all. Idle and failed sessions clear it.
    static func showsCard(state: PlaybackState) -> Bool {
        switch state {
        case .idle, .error: return false
        default: return true
        }
    }

    static func info(state: PlaybackState, elapsed: Double, duration: Double, isLive: Bool,
                     isBuffering: Bool, requestedRate: Float, identity: [String: Any]) -> [String: Any]? {
        guard showsCard(state: state) else { return nil }
        var info = identity
        let finite = elapsed.isFinite ? max(0, elapsed) : 0
        let known = duration.isFinite && duration > 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (state == .ended && known) ? duration : finite
        info[MPNowPlayingInfoPropertyPlaybackRate] =
            playbackRate(state: state, isBuffering: isBuffering, requestedRate: requestedRate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        if known && !isLive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        return info
    }

    static func needsRepublish(publishedElapsed: Double, publishedRate: Double, secondsSincePublish: Double,
                               currentElapsed: Double) -> Bool {
        let expected = publishedElapsed + publishedRate * max(0, secondsSincePublish)
        return abs(currentElapsed - expected) > driftTolerance
    }

    /// Scrubbing and skipping make no sense on a live source with no DVR window; the engine refuses a
    /// live seek anyway, so the buttons are disabled instead of accepted and ignored.
    static func seekingEnabled(isLive: Bool) -> Bool { !isLive }

    @MainActor
    static func perform(_ command: SoftwareNowPlayingCommand, on transport: any SoftwareNowPlayingTransport) {
        switch command {
        case .play: transport.play()
        case .pause: transport.pause()
        case .togglePlayPause: transport.togglePlayPause()
        case .skip(let seconds):
            let target = skipTarget(current: transport.currentTime, delta: seconds, duration: transport.duration)
            Task { @MainActor in await transport.seek(to: target) }
        case .changePosition(let position):
            let target = skipTarget(current: position, delta: 0, duration: transport.duration)
            Task { @MainActor in await transport.seek(to: target) }
        }
    }

    static func skipTarget(current: Double, delta: Double, duration: Double) -> Double {
        let raw = (current.isFinite ? current : 0) + delta
        let upper = (duration.isFinite && duration > 0) ? duration : raw
        return min(max(0, raw), upper)
    }
}

/// Publishes the software host's Now-Playing card and routes the system's remote commands to the engine.
/// The AVPlayer paths get both from their player; the software host has none, so this fills the same
/// role by hand. Elapsed time is only published on discontinuities (state, rate, duration, a clock jump):
/// the system extrapolates between them from the published rate.
@MainActor
final class SoftwareNowPlayingController {
    private let sink: SoftwareNowPlayingSink
    private weak var transport: (any SoftwareNowPlayingTransport)?
    private var identity: [String: Any] = [:]
    private var intendedPlaying = false
    private var published: (elapsed: Double, rate: Double, at: TimeInterval)?
    private let uptime: () -> TimeInterval

    init(sink: SoftwareNowPlayingSink, transport: any SoftwareNowPlayingTransport,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink
        self.transport = transport
        self.uptime = uptime
    }

    func start() {
        sink.activate { [weak self] command in
            guard let transport = self?.transport else { return }
            SoftwareNowPlayingPolicy.perform(command, on: transport)
        }
    }

    func stop() {
        sink.deactivate()
        published = nil
    }

    /// Per-item identity (title, artwork, ...). Empty clears it.
    func setIdentity(_ info: [String: Any]) {
        identity = info
        refresh(requestedRate: nil, isBuffering: false, force: true)
    }

    /// A state, rate, duration, buffering or live change: always republishes.
    func refresh(requestedRate: Float?, isBuffering: Bool, force: Bool = true) {
        guard let transport else { return }
        let state = transport.state
        if state == .playing { intendedPlaying = true } else if state == .paused { intendedPlaying = false }
        let rate = requestedRate ?? lastRequestedRate
        lastRequestedRate = rate
        lastBuffering = isBuffering
        let info = SoftwareNowPlayingPolicy.info(
            state: state, elapsed: transport.currentTime, duration: transport.duration,
            isLive: transport.isLive, isBuffering: isBuffering, requestedRate: rate, identity: identity)
        sink.setSeekingEnabled(SoftwareNowPlayingPolicy.seekingEnabled(isLive: transport.isLive))
        sink.publish(info: info,
                     playbackState: SoftwareNowPlayingPolicy.playbackState(state: state,
                                                                          intendedPlaying: intendedPlaying))
        if let info {
            published = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
                         info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0, uptime())
        } else {
            published = nil
        }
    }

    /// The ~10 Hz clock: republish only when the position left the extrapolation the system holds.
    func clockTick(_ elapsed: Double) {
        guard let published else { return }
        if SoftwareNowPlayingPolicy.needsRepublish(
            publishedElapsed: published.elapsed, publishedRate: published.rate,
            secondsSincePublish: uptime() - published.at, currentElapsed: elapsed) {
            refresh(requestedRate: nil, isBuffering: lastBuffering)
        }
    }

    private var lastRequestedRate: Float = 1
    private var lastBuffering = false
}

/// Identity keys for the card, taken from the AVKit `externalMetadata` the host already stages for the
/// AVPlayer path, so one staging call serves whichever host plays.
enum SoftwareNowPlayingIdentity {
    @MainActor
    static func make(from items: [AVMetadataItem]) async -> [String: Any] {
        var info: [String: Any] = [:]
        for item in items {
            switch item.identifier {
            case .commonIdentifierTitle:
                if let v = try? await item.load(.stringValue) { info[MPMediaItemPropertyTitle] = v }
            case .commonIdentifierArtist:
                if let v = try? await item.load(.stringValue) { info[MPMediaItemPropertyArtist] = v }
            case .commonIdentifierAlbumName:
                if let v = try? await item.load(.stringValue) { info[MPMediaItemPropertyAlbumTitle] = v }
            case .commonIdentifierArtwork:
                if let data = try? await item.load(.dataValue), let art = artwork(from: data) {
                    info[MPMediaItemPropertyArtwork] = art
                }
            default: break
            }
        }
        return info
    }

    /// Decoded once up front: the request handler may run off the main thread, and a lazy decode there
    /// is what the staged-dictionary contract on the AVPlayer paths also avoids.
    static func artwork(from data: Data) -> MPMediaItemArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let box = UncheckedImage(image: image)
        return MPMediaItemArtwork(boundsSize: size) { _ in box.platformImage }
    }

    private struct UncheckedImage: @unchecked Sendable {
        let image: CGImage
        #if canImport(UIKit)
        var platformImage: UIImage { UIImage(cgImage: image) }
        #else
        var platformImage: NSImage { NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        #endif
    }
}

/// MediaPlayer-backed sink. iOS and tvOS bring a player-less `MPNowPlayingSession` (the documented route
/// for a non-AVPlayer engine) so the app stays the active Now-Playing app across a pause; macOS has no
/// session type and uses the shared centers.
@MainActor
final class SystemNowPlayingSink: SoftwareNowPlayingSink {
    #if os(iOS) || os(tvOS)
    private let session: MPNowPlayingSession = {
        let s = MPNowPlayingSession(players: [])
        s.automaticallyPublishesNowPlayingInfo = false
        return s
    }()
    private var infoCenter: MPNowPlayingInfoCenter { session.nowPlayingInfoCenter }
    private var commandCenter: MPRemoteCommandCenter { session.remoteCommandCenter }
    var nowPlayingSession: MPNowPlayingSession { session }
    #else
    private var infoCenter: MPNowPlayingInfoCenter { .default() }
    private var commandCenter: MPRemoteCommandCenter { .shared() }
    #endif
    private var tokens: [(MPRemoteCommand, Any)] = []

    func activate(handler: @escaping @MainActor (SoftwareNowPlayingCommand) -> Void) {
        let c = commandCenter
        func add(_ command: MPRemoteCommand, _ make: @escaping @Sendable (MPRemoteCommandEvent) -> SoftwareNowPlayingCommand?) {
            command.isEnabled = true
            let token = command.addTarget { event in
                guard let decoded = make(event) else { return .commandFailed }
                Task { @MainActor in handler(decoded) }
                return .success
            }
            tokens.append((command, token))
        }
        add(c.playCommand) { _ in .play }
        add(c.pauseCommand) { _ in .pause }
        add(c.togglePlayPauseCommand) { _ in .togglePlayPause }
        let interval = NSNumber(value: SoftwareNowPlayingPolicy.skipInterval)
        c.skipForwardCommand.preferredIntervals = [interval]
        c.skipBackwardCommand.preferredIntervals = [interval]
        add(c.skipForwardCommand) { ($0 as? MPSkipIntervalCommandEvent).map { .skip(seconds: $0.interval) } }
        add(c.skipBackwardCommand) { ($0 as? MPSkipIntervalCommandEvent).map { .skip(seconds: -$0.interval) } }
        add(c.changePlaybackPositionCommand) {
            ($0 as? MPChangePlaybackPositionCommandEvent).map { .changePosition(to: $0.positionTime) }
        }
        #if os(iOS) || os(tvOS)
        session.becomeActiveIfPossible(completion: { _ in })
        #endif
    }

    func setSeekingEnabled(_ enabled: Bool) {
        let c = commandCenter
        c.skipForwardCommand.isEnabled = enabled
        c.skipBackwardCommand.isEnabled = enabled
        c.changePlaybackPositionCommand.isEnabled = enabled
    }

    func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = playbackState
    }

    func deactivate() {
        for (command, token) in tokens { command.removeTarget(token) }
        tokens.removeAll()
        publish(info: nil, playbackState: .stopped)
    }
}
