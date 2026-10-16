import Testing
import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The software host (Dolby Vision FEL, AV1 and VP9 without a hardware decoder) decodes audio to PCM,
/// which loses Atmos. These pin which tracks leave that route, and the pieces of the compressed
/// E-AC-3 route that the renderer is picky about.
@Suite("Software host Atmos routes")
struct SoftwareAtmosRouteTests {

    private func route(
        codec: AVCodecID, profile: Int32 = 0, rate: Int32 = 48_000, channels: Int32 = 6,
        frame: Int32 = 1536, live: Bool = false, rendering: ObjectAudioRendering = .apac(.l714),
        joc: Bool = true, apacOS: Bool = true
    ) -> SoftwareAtmosRoute {
        SoftwareAtmosRoute.route(
            codecID: codec, profile: profile, sampleRate: rate, channels: channels,
            framesPerPacket: frame, isLive: live, rendering: rendering, confirmedJOC: joc,
            osSupportsAPAC: apacOS)
    }

    @Test("JOC E-AC-3 goes to the renderer compressed")
    func jocCompressed() {
        #expect(route(codec: AV_CODEC_ID_EAC3) == .compressedEAC3JOC)
        #expect(route(codec: AV_CODEC_ID_EAC3, frame: 0) == .compressedEAC3JOC)
    }

    @Test("object audio off keeps every codec on the PCM decode")
    func offIsPCM() {
        #expect(route(codec: AV_CODEC_ID_EAC3, rendering: .off) == .pcm)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, channels: 8, frame: 0,
                      rendering: .off) == .pcm)
    }

    @Test("live sessions keep the PCM decode")
    func liveIsPCM() {
        #expect(route(codec: AV_CODEC_ID_EAC3, live: true) == .pcm)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, live: true) == .pcm)
    }

    @Test("E-AC-3 without JOC, or in a shape the Atmos decoder is not described for, stays PCM")
    func nonJOC() {
        #expect(route(codec: AV_CODEC_ID_EAC3, joc: false) == .pcm)
        #expect(route(codec: AV_CODEC_ID_EAC3, channels: 8) == .pcm)
        #expect(route(codec: AV_CODEC_ID_EAC3, rate: 44_100) == .pcm)
        #expect(route(codec: AV_CODEC_ID_EAC3, frame: 768) == .pcm)
        #expect(route(codec: AV_CODEC_ID_AC3) == .pcm)
    }

    @Test("TrueHD Atmos and DTS-HD MA render as APAC on an OS that has the encoder")
    func apacRoutes() {
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, channels: 8, frame: 0)
                == .apac(.l714))
        #expect(route(codec: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA, channels: 8, frame: 0,
                      rendering: .apac(.l512)) == .apac(.l512))
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, apacOS: false) == .pcm)
    }

    @Test("TrueHD without Atmos, lossy DTS and a rate other than 48 kHz stay PCM")
    func apacIneligible() {
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: 0) == .pcm)
        #expect(route(codec: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS) == .pcm)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, rate: 96_000) == .pcm)
        #expect(route(codec: AV_CODEC_ID_AAC) == .pcm)
    }

    // MARK: - dec3

    /// The box AVFoundation's own format description carries for a 5.1 JOC stream.
    private static let jocBox = Data([0, 0, 0, 0x0f, 0x64, 0x65, 0x63, 0x33, 0x0e, 0, 0x20, 0x0f, 0, 0x01, 0x0c])
    private static let plainBox = Data([0, 0, 0, 0x0d, 0x64, 0x65, 0x63, 0x33, 0x0e, 0, 0x20, 0x0f, 0])

    @Test("the format description carries the dec3 box as its magic cookie, and the JOC flag reads back")
    func formatDescriptionCookie() throws {
        let description = try #require(SoftwareEAC3Passthrough.formatDescription(dec3Box: Self.jocBox))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatEnhancedAC3)
        #expect(asbd.mFramesPerPacket == 1536)
        #expect(asbd.mChannelsPerFrame == 6)
        var size = 0
        let cookie = try #require(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
        #expect(Data(bytes: cookie, count: size) == Self.jocBox)
        #expect(RemoteHLSStreamDescription.eac3CarriesJOC(dec3: Self.jocBox))
        #expect(!RemoteHLSStreamDescription.eac3CarriesJOC(dec3: Self.plainBox))
    }

    @Test("a box is found by its type and checked against its size")
    func findBox() {
        let junk: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let bytes = junk + [UInt8](Self.jocBox) + junk
        bytes.withUnsafeBufferPointer { buffer in
            #expect(SoftwareEAC3Passthrough.findBox("dec3", in: buffer) == Self.jocBox)
            #expect(SoftwareEAC3Passthrough.findBox("dac3", in: buffer) == nil)
        }
        // A type code whose size runs past the end is not a box.
        let truncated = Array(junk + [UInt8](Self.jocBox).dropLast(4))
        truncated.withUnsafeBufferPointer { #expect(SoftwareEAC3Passthrough.findBox("dec3", in: $0) == nil) }
    }

    @Test("FFmpeg's muxer builds a dec3 box from a real E-AC-3 packet, and a plain stream is not JOC")
    func dec3FromRealPacket() throws {
        var packet = try Self.encodedEAC3Packet()
        defer { av_packet_free(&packet) }
        let par = try #require(avcodec_parameters_alloc())
        var owned: UnsafeMutablePointer<AVCodecParameters>? = par
        defer { avcodec_parameters_free(&owned) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_EAC3
        par.pointee.sample_rate = 48_000
        av_channel_layout_default(&par.pointee.ch_layout, 6)
        let pkt = try #require(packet)
        let entry = try #require(SoftwareEAC3Passthrough.entry(codecpar: par, packet: pkt))
        #expect(!entry.carriesJOC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(entry.formatDescription)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatEnhancedAC3)
    }

    @Test("a packet becomes a one-sample buffer stamped where the source puts it")
    func sampleBuffer() throws {
        let description = try #require(SoftwareEAC3Passthrough.formatDescription(dec3Box: Self.jocBox))
        let bytes = [UInt8](repeating: 0xAB, count: 1792)
        let made = bytes.withUnsafeBytes {
            SoftwareEAC3Passthrough.sampleBuffer(bytes: $0, seconds: 12.5, formatDescription: description)
        }
        let buffer = try #require(made)
        #expect(CMSampleBufferGetNumSamples(buffer) == 1)
        #expect(CMSampleBufferGetPresentationTimeStamp(buffer).seconds == 12.5)
        #expect(abs(CMSampleBufferGetDuration(buffer).seconds - 1536.0 / 48000.0) < 1e-6)
        #expect(CMSampleBufferGetTotalSampleSize(buffer) == 1792)
    }

    /// One E-AC-3 access unit of silence from libavcodec's own encoder.
    private static func encodedEAC3Packet() throws -> UnsafeMutablePointer<AVPacket>? {
        let codec = try #require(avcodec_find_encoder(AV_CODEC_ID_EAC3))
        var ctx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        c.pointee.sample_rate = 48_000
        c.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        c.pointee.bit_rate = 448_000
        av_channel_layout_default(&c.pointee.ch_layout, 6)
        c.pointee.time_base = AVRational(num: 1, den: 48_000)
        #expect(avcodec_open2(c, codec, nil) >= 0)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.nb_samples = 1536
        f.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        f.pointee.sample_rate = 48_000
        av_channel_layout_default(&f.pointee.ch_layout, 6)
        #expect(av_frame_get_buffer(f, 0) >= 0)
        for plane in 0..<6 {
            if let data = f.pointee.extended_data[plane] { memset(data, 0, 1536 * 4) }
        }
        #expect(avcodec_send_frame(c, f) >= 0)
        _ = avcodec_send_frame(c, nil)
        let packet = av_packet_alloc()
        guard avcodec_receive_packet(c, packet) >= 0 else { return nil }
        return packet
    }
}
