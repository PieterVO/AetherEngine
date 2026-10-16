import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension SoftwarePlaybackHost {

    /// Picks and builds the audio producer for the session's track: the PCM decode every session had,
    /// or one of the two Atmos routes (`SoftwareAtmosRoute`). Every way an Atmos route can be
    /// unavailable (a stream that is not JOC, an OS without the APAC encoder, a build without the
    /// object decoder, a bridge that fails to build) lands on the PCM decode, each logged, so asking
    /// for Atmos never costs a session its audio.
    func makeAudioProducer(
        demuxer dem: Demuxer, streamIndex: Int32, isLive: Bool
    ) async throws -> (producer: any SoftwareAudioProducing, route: SoftwareAtmosRoute) {
        guard let stream = dem.stream(at: streamIndex), let par = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }
        func pcm() throws -> (producer: any SoftwareAudioProducing, route: SoftwareAtmosRoute) {
            let decoder = AudioDecoder()
            try decoder.open(stream: stream)
            return (decoder, .pcm)
        }
        guard objectAudioRendering != .off, !isLive else { return try pcm() }

        var joc: SoftwareEAC3Passthrough.Entry?
        if par.pointee.codec_id == AV_CODEC_ID_EAC3 {
            joc = await BlockingWork.detached(priority: .userInitiated) {
                Self.firstEAC3Entry(demuxer: dem, streamIndex: streamIndex)
            }.value
        }
        let route = SoftwareAtmosRoute.route(
            codecID: par.pointee.codec_id, profile: par.pointee.profile,
            sampleRate: par.pointee.sample_rate, channels: par.pointee.ch_layout.nb_channels,
            framesPerPacket: par.pointee.frame_size, isLive: isLive,
            rendering: objectAudioRendering, confirmedJOC: joc?.carriesJOC == true)
        switch route {
        case .pcm:
            if par.pointee.codec_id == AV_CODEC_ID_EAC3 {
                EngineLog.emit("[SWHost] audio: E-AC-3 stays PCM (JOC=\(joc?.carriesJOC == true) "
                               + "channels=\(par.pointee.ch_layout.nb_channels))", category: .swPlayback)
            }
            return try pcm()
        case .compressedEAC3JOC:
            guard let joc else { return try pcm() }
            do {
                let producer = try SoftwareEAC3Passthrough(stream: stream, formatDescription: joc.formatDescription)
                // The registration takes a moment; it runs while the rest of the load does.
                AtmosDecoderPrimer.shared.begin()
                EngineLog.emit("[SWHost] audio: E-AC-3 JOC goes to the renderer compressed (Atmos decode)",
                               category: .swPlayback)
                return (producer, route)
            } catch {
                EngineLog.emit("[SWHost] audio: E-AC-3 JOC passthrough unavailable (\(error)); PCM decode",
                               category: .swPlayback)
                return try pcm()
            }
        case .apac(let layout):
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return try pcm() }
            if let producer = await makeAPACProducer(demuxer: dem, stream: stream, streamIndex: streamIndex, layout: layout) {
                return (producer, route)
            }
            return try pcm()
        }
    }

    /// The first E-AC-3 access unit of the stream, looked at without consuming it.
    nonisolated static func firstEAC3Entry(demuxer: Demuxer, streamIndex: Int32) -> SoftwareEAC3Passthrough.Entry? {
        guard let par = demuxer.stream(at: streamIndex)?.pointee.codecpar else { return nil }
        var entry: SoftwareEAC3Passthrough.Entry?
        var heldBytes = 0
        try? demuxer.peekPackets(maxPackets: SoftwareAtmosRoute.jocPeekPacketBudget) { packet in
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > SoftwareAtmosRoute.jocPeekByteBudget { return true }
            guard packet.pointee.stream_index == streamIndex, packet.pointee.size > 0 else { return false }
            entry = SoftwareEAC3Passthrough.entry(codecpar: par, packet: packet)
            return true
        }
        return entry
    }

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func makeAPACProducer(
        demuxer dem: Demuxer, stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32,
        layout: SpatialSpeakerLayout
    ) async -> (any SoftwareAudioProducing)? {
        let par = stream.pointee.codecpar.pointee
        guard let source = HLSVideoEngine.objectAudioSource(codecID: par.codec_id, profile: par.profile) else { return nil }
        let decoder: ObjectAudioDecoding
        do {
            switch source {
            case .trueHDAtmos:
                #if TrueHDObjectAudio
                decoder = try TrueHDObjectAudioDecoder()
                #else
                EngineLog.emit("[SWHost] audio: built without the TrueHDObjectAudio trait; PCM decode", category: .swPlayback)
                return nil
                #endif
            case .dtsHDMasterAudio:
                #if DTSXObjectAudio
                let dtsx = try DTSXObjectAudioDecoder()
                // The detached task is the only user of the decoder until it returns.
                nonisolated(unsafe) let verdictDecoder = dtsx
                let verdict = await BlockingWork.detached(priority: .userInitiated) {
                    HLSVideoEngine.dtsxVerdict(decoder: verdictDecoder, demuxer: dem, streamIndex: streamIndex)
                }.value
                guard case .renders(let presentation) = verdict else {
                    EngineLog.emit("[SWHost] audio: DTS-HD MA track is not DTS:X this build renders; PCM decode",
                                   category: .swPlayback)
                    return nil
                }
                EngineLog.emit("[SWHost] audio: DTS-HD MA track is DTS:X \(presentation)", category: .swPlayback)
                dtsx.reset()
                decoder = dtsx
                #else
                EngineLog.emit("[SWHost] audio: built without the DTSXObjectAudio trait; PCM decode", category: .swPlayback)
                return nil
                #endif
            }
            let bridge = try SpatialAudioBridge(srcTimeBase: stream.pointee.time_base, layout: layout, decoder: decoder)
            let tap = AudioDecoder()
            let tapDecoder: AudioDecoder? = (try? tap.open(stream: stream)) != nil ? tap : nil
            bridge.onDecoderProducedNothing = { stats in
                EngineLog.emit("[SWHost] ERROR: \(source.name) object decoder produced nothing: \(stats.summary)",
                               category: .swPlayback)
            }
            EngineLog.emit("[SWHost] audio: \(source.name) rendered into \(layout.rawValue) as APAC for the renderer",
                           category: .swPlayback)
            return SoftwareAPACProducer(bridge: bridge, tapDecoder: tapDecoder)
        } catch {
            EngineLog.emit("[SWHost] audio: \(source.name) APAC route unavailable (\(error)); PCM decode",
                           category: .swPlayback)
            return nil
        }
    }
}
