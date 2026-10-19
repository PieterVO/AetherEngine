// Sources/AetherEngine/Video/CompositorPreviewBuilder.swift
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Wraps the first keyframe of a resident segment into a standalone fMP4 (init + one fragment), so a
/// second AVPlayer can show it through the system compositor. That is the only place a Dolby Vision
/// Profile 5 / 10.0 picture gets its colour on Apple platforms: no still API applies the RPU, and an
/// `AVPlayerItemVideoOutput` on the item switches that processing off for the layer too.
///
/// The packet comes out of the segment the session already muxed, so it carries every conversion the
/// playing picture got, and the init is rebuilt from the segment's own demuxed parameters: the
/// sample entry, `dvcC` and `colr` therefore say what the playing item says. The init carries no
/// audio track, so the preview item has nothing to wait for.
enum CompositorPreviewBuilder {
    struct Output {
        let file: Data
        /// Seconds from the segment's first frame to the keyframe, on the segment's own clock.
        let keyframeOffsetSeconds: Double
    }

    static func build(initData: Data, segmentURL: URL, durationSeconds: Double,
                      codecTagOverride: String?, colorOverride: MP4SegmentMuxer.ColorOverride?,
                      stagingDir: URL) -> Output? {
        guard let segment = try? Data(contentsOf: segmentURL, options: .alwaysMapped) else { return nil }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(reader: DataIOReader(parts: [initData, segment]), formatHint: "mp4",
                             profile: .stillExtraction)
        } catch {
            return nil
        }
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx),
              let codecpar = stream.pointee.codecpar else { return nil }
        demuxer.discardAllStreamsExcept([videoIdx])
        let timeBase = stream.pointee.time_base
        guard timeBase.num > 0, timeBase.den > 0 else { return nil }

        var payload: Data?
        var firstPts: Int64?
        var keyPts: Int64?
        // The segment opens on its keyframe; a bound keeps a malformed one from walking the file.
        for _ in 0..<64 {
            guard let packet = try? demuxer.readPacket() else { break }
            defer { av_packet_unref(packet); av_packet_free_safe(packet) }
            guard packet.pointee.stream_index == videoIdx else { continue }
            let pts = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
            if firstPts == nil { firstPts = pts }
            guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0, let data = packet.pointee.data,
                  packet.pointee.size > 0 else { continue }
            payload = Data(bytes: data, count: Int(packet.pointee.size))
            keyPts = pts
            break
        }
        guard let payload, let keyPts else { return nil }

        let builder = IFrameFragmentBuilder(
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(codecpar), timeBase: timeBase,
                codecTagOverride: codecTagOverride, doviConfig: .keep,
                colorOverride: colorOverride),
            stagingDir: stagingDir)
        guard let output = builder.build(payload: payload, index: 0, startSeconds: 0,
                                         durationSeconds: max(durationSeconds, 0.04)) else { return nil }
        let ticks = Double(timeBase.num) / Double(timeBase.den)
        let offset = firstPts.map { Double(keyPts - $0) * ticks } ?? 0
        return Output(file: output.initSegment + output.fragment, keyframeOffsetSeconds: max(0, offset))
    }
}
