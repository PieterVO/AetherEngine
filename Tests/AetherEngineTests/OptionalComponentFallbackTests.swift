import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The object renderer and the dual-layer composer are compiled only with their package traits, all off
/// by default. A build without one still accepts the option that asks for it, and the option changes
/// nothing: object audio keeps the channel bridge, a Profile 7 source keeps the native route. The track
/// pick is pinned the same way in `AudioLanguageSelectionTests.withoutTraitNothingIsPreferred`.
@Suite("Optional components fall back when their trait is off")
struct OptionalComponentFallbackTests {

    #if !DualLayerDolbyVision
    private static let uhd24 = DualLayerRouteDecision.Geometry(width: 3840, height: 2160, frameRate: 24)

    private static func decide(prefer: Bool) -> DualLayerRouteDecision {
        DualLayerRouteDecision.decide(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: prefer, isLive: false, isSourceSeekable: true,
            canHardwareDecode: { true }, elType: "FEL", geometry: uhd24)
    }

    @Test("preferDualLayerDolbyVision keeps a Profile 7 FEL source on the native route and says why")
    func dualLayerPreferenceKeepsNativeRoute() {
        #expect(!DualLayerRouteDecision.isBuiltIn)
        #expect(Self.decide(prefer: true) == .notTaken(.notBuiltIn))
        #expect(Self.decide(prefer: true).logLine
                == "[AetherEngine] DV P7 dual-layer route: not taken (built without the DualLayerDolbyVision trait), "
                + "keeps the native route (8.1 where the display takes Dolby Vision)")
        #expect(Self.decide(prefer: false) == .notTaken(.preferenceOff), "not asking is still reported as such")
        #expect(!VideoRoutingPolicy.dualLayerRouteIsWanted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true, canHardwareDecode: { true }),
            "no el_type probe for a route that cannot be taken")
        for prefer in [true, false] {
            #expect(!VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
                dvProfile: 7, preferDualLayerDolbyVision: prefer, canHardwareDecode: { true }, elType: "FEL"))
        }
    }
    #endif

    #if !TrueHDObjectAudio
    @Test("objectAudioRendering keeps TrueHD Atmos on the channel bridge")
    func trueHDAtmosKeepsChannelBridge() {
        #expect(HLSVideoEngine.objectAudioSource(codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS) == .trueHDAtmos)
        #expect(HLSVideoEngine.ObjectAudioSource.trueHDAtmos.isBuiltIn == false)
        for layout in SpatialSpeakerLayout.allCases {
            #expect(HLSVideoEngine.spatialRenderingLayout(
                rendering: .apac(layout), codecID: AV_CODEC_ID_TRUEHD,
                profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 48_000) == nil)
        }
    }
    #endif

    #if !DTSXObjectAudio
    @Test("objectAudioRendering keeps DTS-HD Master Audio on the channel bridge")
    func dtsHDMasterAudioKeepsChannelBridge() {
        #expect(HLSVideoEngine.ObjectAudioSource.dtsHDMasterAudio.isBuiltIn == false)
        for profile in [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX] {
            #expect(HLSVideoEngine.objectAudioSource(codecID: AV_CODEC_ID_DTS, profile: profile) == .dtsHDMasterAudio)
            #expect(HLSVideoEngine.spatialRenderingLayout(
                rendering: .apac(.l714), codecID: AV_CODEC_ID_DTS, profile: profile, sampleRate: 48_000) == nil)
        }
    }
    #endif
}
