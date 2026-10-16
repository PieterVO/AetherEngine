import Testing
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
@testable import AetherEngine

/// The software host reads the system caption style itself (there is no AVKit legible output to
/// apply it), so what is tested is the mapping from the system's values to a style, how a style
/// resolves against a cue's own styling, and that a style change reaches the rendered overlay.
@Suite("System caption style for software subtitles")
struct SubtitleCaptionStyleTests {

    private typealias System = SubtitleCaptionStyle.SystemValues

    private static let white = SubtitleColor(r: 255, g: 255, b: 255)
    private static let black = SubtitleColor(r: 0, g: 0, b: 0)

    /// A system with nothing customised: every property yields to the content.
    private static func untouched() -> System {
        System(fontName: .init(value: "Helvetica", overridden: false), sizeScale: 1,
               textColor: .init(value: white, overridden: false),
               textOpacity: .init(value: 1, overridden: false),
               backgroundColor: .init(value: black, overridden: false),
               backgroundOpacity: .init(value: 0.5, overridden: false),
               windowColor: .init(value: black, overridden: false),
               windowOpacity: .init(value: 0, overridden: false),
               edgeStyle: .init(value: .dropShadow, overridden: false))
    }

    // MARK: - Mapping

    @Test("a system with no customisation reads as the standard look")
    func untouchedIsStandard() {
        #expect(SubtitleCaptionStyle(Self.untouched()) == .standard)
    }

    @Test("only the properties the user overrode come through")
    func overridesOnly() {
        var system = Self.untouched()
        system.fontName = .init(value: "Courier", overridden: true)
        system.textColor = .init(value: SubtitleColor(r: 255, g: 255, b: 0), overridden: true)
        system.backgroundOpacity = .init(value: 0, overridden: true)
        system.edgeStyle = .init(value: .uniform, overridden: true)
        system.sizeScale = 1.5
        // Not overridden, so the stale values the system still reports must not leak through.
        system.windowOpacity = .init(value: 0.8, overridden: false)

        let style = SubtitleCaptionStyle(system)
        #expect(style.fontName == "Courier")
        #expect(style.textColor == SubtitleColor(r: 255, g: 255, b: 0))
        #expect(style.backgroundOpacity == 0)
        #expect(style.edgeStyle == .uniform)
        #expect(style.sizeScale == 1.5)
        #expect(style.windowOpacity == nil)
        #expect(style.textOpacity == nil)
        #expect(style.backgroundColor == nil)
    }

    @Test("a nonsense character size falls back to one")
    func invalidSize() {
        for bad in [0.0, -1.0, .nan] {
            var system = Self.untouched()
            system.sizeScale = bad
            #expect(SubtitleCaptionStyle(system).sizeScale == 1)
        }
    }

    @Test("system edge styles map one to one, and undefined means no preference")
    func edgeStyles() {
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 1) == SubtitleCaptionStyle.EdgeStyle.none)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 2) == .raised)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 3) == .depressed)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 4) == .uniform)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 5) == .dropShadow)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 0) == nil)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 99) == nil)
    }

    @Test("reading the live system does not trap and is stable between reads")
    func liveRead() {
        #expect(SubtitleCaptionStyle.current() == SubtitleCaptionStyle.current())
    }

    // MARK: - Resolution

    private func components(_ color: CGColor) -> [CGFloat] { color.components ?? [] }

    @Test("text colour: the user's beats the cue's, the cue's beats white")
    func textColorPrecedence() {
        let cue = SubtitleColor(r: 255, g: 0, b: 0)
        #expect(components(SubtitleCaptionStyle.standard.resolvedTextColor(cueColor: cue)) == [1, 0, 0, 1])
        #expect(components(SubtitleCaptionStyle.standard.resolvedTextColor(cueColor: nil)) == [1, 1, 1, 1])
        let user = SubtitleCaptionStyle(textColor: SubtitleColor(r: 0, g: 255, b: 0), textOpacity: 0.5)
        #expect(components(user.resolvedTextColor(cueColor: cue)) == [0, 1, 0, 0.5])
    }

    @Test("background keeps the old look until the user changes it, and can be switched off")
    func backgroundResolution() {
        #expect(components(SubtitleCaptionStyle.standard.resolvedBackground!) == [0, 0, 0, 0.6])
        #expect(SubtitleCaptionStyle(backgroundOpacity: 0).resolvedBackground == nil)
        let blue = SubtitleCaptionStyle(backgroundColor: SubtitleColor(r: 0, g: 0, b: 255), backgroundOpacity: 1)
        #expect(components(blue.resolvedBackground!) == [0, 0, 1, 1])
    }

    @Test("the window is off unless the user turned it on")
    func windowResolution() {
        #expect(SubtitleCaptionStyle.standard.resolvedWindow == nil)
        #expect(SubtitleCaptionStyle(windowOpacity: 0).resolvedWindow == nil)
        #expect(components(SubtitleCaptionStyle(windowOpacity: 0.4).resolvedWindow!) == [0, 0, 0, 0.4])
    }

    @Test("the user's font beats the cue's, and the size scales the frame-relative base")
    func fontAndSize() {
        let run = SubtitleTextRun(text: "x", color: nil, fontName: "Times-Roman")
        let cue = SubtitleFrameCompositor.font(for: run, baseSize: 40)
        let user = SubtitleFrameCompositor.font(for: run, baseSize: 40, style: SubtitleCaptionStyle(fontName: "Courier"))
        #expect(CTFontCopyPostScriptName(cue) as String == "Times-Roman")
        #expect(CTFontCopyPostScriptName(user) as String == "Courier")

        let base = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080)
        let big = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080, sizeScale: 2)
        #expect(big.fontSize == base.fontSize * 2)
        #expect(big.maxTextWidth == base.maxTextWidth)
    }

    // MARK: - Rendering

    private func opaquePixels(_ image: CGImage) -> Int {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return stride(from: 3, to: image.width * image.height * 4, by: 4).filter { bytes[$0] > 0 }.count
    }

    private let cue = SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Caption style"))

    @Test("a transparent background and a window change what is drawn")
    func overlayFollowsStyle() throws {
        func render(_ style: SubtitleCaptionStyle) throws -> Int {
            opaquePixels(try #require(SubtitleFrameCompositor.renderOverlay(
                for: [cue], frameWidth: 640, frameHeight: 360, style: style)))
        }
        let standard = try render(.standard)
        let bare = try render(SubtitleCaptionStyle(backgroundOpacity: 0))
        let windowed = try render(SubtitleCaptionStyle(backgroundOpacity: 0, windowOpacity: 1))
        let outlined = try render(SubtitleCaptionStyle(backgroundOpacity: 0, edgeStyle: .uniform))
        #expect(bare > 0)
        #expect(bare < standard)
        #expect(windowed > bare)
        #expect(outlined > bare)
    }

    @Test("the default style renders the same overlay as before styles existed")
    func standardIsUnchanged() throws {
        let plain = try #require(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 640, frameHeight: 360))
        let styled = try #require(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 640, frameHeight: 360,
                                                                        style: .standard))
        #expect(plain.dataProvider?.data == styled.dataProvider?.data)
    }

    private func frameBytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    @Test("a style change reaches the next composited frame, not just the next cue")
    func styleChangeInvalidatesCache() throws {
        var source: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source)
        let input = try #require(source)
        CVPixelBufferLockBaseAddress(input, [])
        memset(CVPixelBufferGetBaseAddress(input), 0x40, CVPixelBufferGetBytesPerRow(input) * 180)
        CVPixelBufferUnlockBaseAddress(input, [])

        let compositor = SubtitleFrameCompositor(styleProvider: { .standard }, observesSystemStyle: false)
        compositor.update(cues: [cue], enabled: true, delaySeconds: 0)
        let before = frameBytes(compositor.composite(input, ptsSeconds: 1))
        #expect(before != frameBytes(input))
        #expect(before == frameBytes(compositor.composite(input, ptsSeconds: 1.1)))

        compositor.setStyle(SubtitleCaptionStyle(backgroundOpacity: 0, windowOpacity: 1))
        let after = frameBytes(compositor.composite(input, ptsSeconds: 1.2))
        #expect(after != before)
    }
}
