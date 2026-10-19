import Foundation

/// Where a compositor-drawn scrub preview landed (`AetherEngine.showScrubPreview(atSeconds:in:)`).
public struct ScrubPreviewPlacement: Sendable, Equatable {
    /// Playlist/output seconds of the keyframe on screen.
    public let actualSeconds: Double
    /// The span the same picture stands for: the resident segment that keyframe opens.
    public let validRange: Range<Double>
}

extension AetherEngine {

    /// True when this session's scrub previews come through `showScrubPreview(atSeconds:in:)` and an
    /// `AetherScrubPreviewView` rather than a `CGImage`: a native VOD session of Dolby Vision without
    /// a displayable base layer (Profile 5, AV1 Profile 10.0), whose colour only the system
    /// compositor applies. Independent of the `DolbyVisionStillReshaping` trait, and needs no second
    /// connection: the picture comes out of the resident segments, like `scrubThumbnail`.
    public var scrubPreviewDrawsInView: Bool {
        guard !isLive, let session = nativeVideoSession else { return false }
        return session.previewNeedsCompositor
    }

    /// Shows the keyframe that opens the resident segment holding `seconds` (playlist/output axis,
    /// as `scrubThumbnail` takes it) in `view`. Nil when `scrubPreviewDrawsInView` is false, the
    /// segment is not resident, a newer request on the same view superseded this one, or the session
    /// changed meanwhile; the view keeps its previous picture in every case.
    public func showScrubPreview(atSeconds seconds: Double, in view: AetherScrubPreviewView) async -> ScrubPreviewPlacement? {
        guard seconds.isFinite, scrubPreviewDrawsInView, let session = nativeVideoSession else { return nil }
        let gen = loadGeneration
        let file = await BlockingWork.detached(priority: .userInitiated) { [session] in
            session.compositorPreviewFile(atSeconds: seconds)
        }.value
        guard let file, gen == loadGeneration, !Task.isCancelled else { return nil }
        guard await view.present(file.url), gen == loadGeneration else { return nil }
        return ScrubPreviewPlacement(actualSeconds: file.startSeconds,
                                     validRange: file.startSeconds..<(file.startSeconds + file.durationSeconds))
    }
}
