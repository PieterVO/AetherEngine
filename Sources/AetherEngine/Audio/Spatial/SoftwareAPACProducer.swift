import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil

/// TrueHD Atmos or DTS:X for the software host: the same render-and-encode bridge the AVPlayer route
/// uses (`SpatialAudioBridge`), with its APAC packets handed to the audio renderer as sample buffers
/// where the HLS route muxes them into fMP4.
///
/// The bridge stamps packet k of an encoder run at the run's anchor plus k * 1024, priming packets
/// included, because AVFoundation presents an APAC packet's audio `encoderLeadingFrames` before its
/// timestamp. A sample buffer carries the presentation time itself, so the shift is applied here:
/// the first content frame lands on the source position and the priming output falls before it.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class SoftwareAPACProducer: SoftwareAudioProducing, @unchecked Sendable {

    private let bridge: SpatialAudioBridge
    private let sampleRate = Double(SpatialAudioBridge.sampleRate)
    /// PCM for the audio tap, which wants the 7.1 channel presentation the renderer is not given.
    /// Opened lazily: most sessions never tap.
    private let tapDecoder: AudioDecoder?

    init(bridge: SpatialAudioBridge, tapDecoder: AudioDecoder?) {
        self.bridge = bridge
        self.tapDecoder = tapDecoder
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        let packets: [UnsafeMutablePointer<AVPacket>]
        do {
            packets = try bridge.feed(packet: packet)
        } catch {
            return []
        }
        let leading = Int64(bridge.encoderLeadingFrames)
        var buffers: [CMSampleBuffer] = []
        for encoded in packets {
            if let data = encoded.pointee.data, encoded.pointee.size > 0,
               let sample = Self.sampleBuffer(
                bytes: UnsafeRawBufferPointer(start: data, count: Int(encoded.pointee.size)),
                seconds: Double(encoded.pointee.pts - leading) / sampleRate,
                formatDescription: bridge.packetFormatDescription) {
                buffers.append(sample)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = encoded
            trackedPacketFree(&owned)
        }
        return buffers
    }

    /// One APAC packet as a one-sample buffer.
    static func sampleBuffer(
        bytes: UnsafeRawBufferPointer, seconds: Double, formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        SoftwareEAC3Passthrough.sampleBuffer(bytes: bytes, seconds: seconds, formatDescription: formatDescription)
    }

    func flush() {
        bridge.startSegment()
        tapDecoder?.flush()
    }

    func close() {
        bridge.close()
        tapDecoder?.close()
    }

    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer] {
        tapDecoder?.decode(packet: packet) ?? []
    }
}
