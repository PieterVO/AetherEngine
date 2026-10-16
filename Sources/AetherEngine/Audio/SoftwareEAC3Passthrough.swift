import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// E-AC-3 JOC for the software host: the packets go to `AVSampleBufferAudioRenderer` compressed,
/// the way the AVPlayer route stream-copies them into its fMP4, so the system's Atmos decoder gets
/// the whole stream (core and objects) instead of libavcodec's 5.1 core.
///
/// The renderer decides what to decode from the format description, and for E-AC-3 it reads the
/// JOC signal out of the `dec3` sample-entry box in the magic cookie. A format description built
/// from the bare stream description (no cookie) decodes as 5.1 even after the Atmos decoder is
/// registered (`AtmosDecoderPrimer`). Neither FFmpeg's demuxers nor Matroska hand the box over, so
/// it is built the way the engine's own muxer builds it: one real packet through FFmpeg's mp4
/// muxer, and the box read back out of the result.
final class SoftwareEAC3Passthrough: SoftwareAudioProducing, @unchecked Sendable {

    /// What a first look at the stream's packets found.
    struct Entry {
        let formatDescription: CMAudioFormatDescription
        let carriesJOC: Bool
    }

    private static let framesPerPacket: Int64 = 1536
    private static let sampleRate: Double = 48_000

    private let formatDescription: CMAudioFormatDescription
    private let timeBase: AVRational
    /// Decodes for the audio tap only: `decode` itself never runs it.
    private let tapDecoder = AudioDecoder()
    private let lock = NSLock()
    /// Where the next packet sits when the container left its stamps out.
    private var nextSeconds: Double?

    init(stream: UnsafeMutablePointer<AVStream>, formatDescription: CMAudioFormatDescription) throws {
        self.formatDescription = formatDescription
        self.timeBase = stream.pointee.time_base
        try tapDecoder.open(stream: stream)
    }

    // MARK: - Format description

    /// The format description for a stream whose first packet is `packet`, and whether that packet
    /// carries the JOC flag. Nil when the box cannot be built, which keeps the PCM decode.
    static func entry(
        codecpar: UnsafePointer<AVCodecParameters>, packet: UnsafePointer<AVPacket>
    ) -> Entry? {
        guard let box = dec3Box(codecpar: codecpar, packet: packet),
              let description = formatDescription(dec3Box: box) else { return nil }
        return Entry(formatDescription: description,
                     carriesJOC: RemoteHLSStreamDescription.eac3CarriesJOC(dec3: box))
    }

    static func formatDescription(dec3Box: Data) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatEnhancedAC3, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: 6, mBitsPerChannel: 0, mReserved: 0)
        // The AC-3 channel order, which is the one the decoder delivers.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_C
        var description: CMAudioFormatDescription?
        let status = dec3Box.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: cookie.count, magicCookie: cookie.baseAddress,
                extensions: nil, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    /// The `dec3` box FFmpeg's mp4 muxer writes for a stream, size and type included, which is the
    /// form AVFoundation's own format descriptions carry as their magic cookie.
    static func dec3Box(codecpar: UnsafePointer<AVCodecParameters>, packet: UnsafePointer<AVPacket>) -> Data? {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "dec3.mp4") == 0, let ctx = ctxOut else { return nil }
        defer { avformat_free_context(ctx) }
        var pb: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&pb) >= 0, let pbCtx = pb else { return nil }
        ctx.pointee.pb = pbCtx
        let written = muxOnePacket(ctx: ctx, codecpar: codecpar, packet: packet)
        var bytes: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(pbCtx, &bytes)
        defer { if bytes != nil { av_free(bytes) } }
        guard written, size > 8, let bytes else { return nil }
        return findBox("dec3", in: UnsafeBufferPointer(start: bytes, count: Int(size)))
    }

    private static func muxOnePacket(
        ctx: UnsafeMutablePointer<AVFormatContext>,
        codecpar: UnsafePointer<AVCodecParameters>, packet: UnsafePointer<AVPacket>
    ) -> Bool {
        guard let stream = avformat_new_stream(ctx, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, codecpar) >= 0 else { return false }
        stream.pointee.codecpar.pointee.codec_tag = 0
        stream.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))
        guard avformat_write_header(ctx, nil) >= 0 else { return false }
        var cloned: UnsafeMutablePointer<AVPacket>? = av_packet_clone(packet)
        defer { av_packet_free(&cloned) }
        guard let copy = cloned else { return false }
        copy.pointee.stream_index = 0
        copy.pointee.pts = 0
        copy.pointee.dts = 0
        copy.pointee.duration = framesPerPacket
        guard av_write_frame(ctx, copy) >= 0 else { return false }
        return av_write_trailer(ctx) >= 0
    }

    /// The first box of `type` in an ISO BMFF byte run, found by its four-character code and checked
    /// against the size in front of it, returned whole.
    static func findBox(_ type: String, in bytes: UnsafeBufferPointer<UInt8>) -> Data? {
        let code = Array(type.utf8)
        guard code.count == 4, bytes.count >= 8 else { return nil }
        for i in 4...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == code {
            let start = i - 4
            let size = (Int(bytes[start]) << 24) | (Int(bytes[start + 1]) << 16)
                | (Int(bytes[start + 2]) << 8) | Int(bytes[start + 3])
            guard size >= 8, start + size <= bytes.count else { continue }
            return Data(bytes[start..<(start + size)])
        }
        return nil
    }

    // MARK: - SoftwareAudioProducing

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        let tb = timeBase
        let ticks = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        let seconds: Double
        lock.lock()
        if ticks != Int64.min, tb.den > 0 {
            seconds = Double(ticks) * Double(tb.num) / Double(tb.den)
        } else if let next = nextSeconds {
            seconds = next
        } else {
            lock.unlock()
            return []
        }
        nextSeconds = seconds + Double(Self.framesPerPacket) / Self.sampleRate
        lock.unlock()
        guard let buffer = Self.sampleBuffer(
            bytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
            seconds: seconds, formatDescription: formatDescription) else { return [] }
        return [buffer]
    }

    /// One compressed packet as a sample buffer of one sample. The bytes are copied: the packet is
    /// freed by the demux loop as soon as `decode` returns.
    static func sampleBuffer(
        bytes: UnsafeRawBufferPointer, seconds: Double, formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: bytes.count) == noErr else { return nil }
        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90_000),
            packetDescriptions: &description, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    func flush() {
        lock.lock()
        nextSeconds = nil
        lock.unlock()
        tapDecoder.flush()
    }

    func close() {
        tapDecoder.close()
    }

    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer] {
        tapDecoder.decode(packet: packet)
    }
}
