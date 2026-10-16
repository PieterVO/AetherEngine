import Testing
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import MediaAccessibility
@testable import AetherEngine

/// The software host reads the system caption style itself (there is no AVKit legible output to
/// apply it), so what is tested is the mapping from the system's values to a style, how a style
/// resolves against a cue's own styling, and that a style change reaches the rendered overlay.
@Suite("System caption style for software subtitles")
struct SubtitleCaptionStyleTests {

    private typealias System = SubtitleCaptionStyle.SystemValues

    private static let white = SubtitleColor(r: 255, g: 255, b: 255)
    private static let black = SubtitleColor(r: 0, g: 0, b: 0)

    /// A system with nothing customised: the user domain reads what the factory default does.
    /// The window opacity is 0.5 with `UseValue` on purpose: the flag ranks the value against a
    /// cue's, it does not say the user changed anything.
    private static func untouched() -> System {
        System(fontName: .init(user: "Helvetica", factory: "Helvetica", useValue: true),
               sizeScale: .init(user: 1, factory: 1),
               textColor: .init(user: white, factory: white),
               textOpacity: .init(user: 1, factory: 1, useValue: true),
               backgroundColor: .init(user: black, factory: black),
               backgroundOpacity: .init(user: 0.5, factory: 0.5),
               windowColor: .init(user: black, factory: black),
               windowOpacity: .init(user: 0.5, factory: 0.5, useValue: true),
               edgeStyle: .init(user: .dropShadow, factory: .dropShadow, useValue: true))
    }

    private func components(_ color: CGColor) -> [CGFloat] { color.components ?? [] }

    // MARK: - Mapping

    @Test("a system with no customisation reads as the standard look, whatever its behaviour flags say")
    func untouchedIsStandard() {
        #expect(SubtitleCaptionStyle(Self.untouched()) == .standard)
    }

    @Test("only the properties that differ from the factory come through, each with its precedence")
    func overridesOnly() {
        var system = Self.untouched()
        system.fontName = .init(user: "Courier", factory: "Helvetica", useValue: true)
        system.textColor = .init(user: SubtitleColor(r: 255, g: 255, b: 0), factory: Self.white, useValue: false)
        system.backgroundOpacity = .init(user: 0, factory: 0.5, useValue: true)
        system.edgeStyle = .init(user: .uniform, factory: .dropShadow, useValue: true)
        system.sizeScale = .init(user: 1.5, factory: 1)

        let style = SubtitleCaptionStyle(system)
        #expect(style.fontName == .init("Courier", precedence: .overridesCue))
        #expect(style.textColor == .init(SubtitleColor(r: 255, g: 255, b: 0), precedence: .yieldsToCue))
        #expect(style.backgroundOpacity == .init(0, precedence: .overridesCue))
        #expect(style.edgeStyle == .init(.uniform, precedence: .overridesCue))
        #expect(style.sizeScale == 1.5)
        #expect(style.windowOpacity == nil)
        #expect(style.textOpacity == nil)
        #expect(style.backgroundColor == nil)
    }

    @Test("a user colour under UseContentIfAvailable is honoured when the cue has none, and yields when it has")
    func contentIfAvailable() {
        var system = Self.untouched()
        let green = SubtitleColor(r: 0, g: 255, b: 0)
        system.textColor = .init(user: green, factory: Self.white, useValue: false)
        let style = SubtitleCaptionStyle(system)
        #expect(components(style.resolvedTextColor(cueColor: nil)) == [0, 1, 0, 1])
        #expect(components(style.resolvedTextColor(cueColor: SubtitleColor(r: 255, g: 0, b: 0))) == [1, 0, 0, 1])

        system.textColor = .init(user: green, factory: Self.white, useValue: true)
        #expect(components(SubtitleCaptionStyle(system).resolvedTextColor(cueColor: SubtitleColor(r: 255, g: 0, b: 0))) == [0, 1, 0, 1])
    }

    @Test("a nonsense character size falls back to one")
    func invalidSize() {
        for bad in [0.0, -1.0, .nan] {
            var system = Self.untouched()
            system.sizeScale = .init(user: bad, factory: 1)
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

    @Test("text colour: the user's beats the cue's, the cue's beats white")
    func textColorPrecedence() {
        let cue = SubtitleColor(r: 255, g: 0, b: 0)
        #expect(components(SubtitleCaptionStyle.standard.resolvedTextColor(cueColor: cue)) == [1, 0, 0, 1])
        #expect(components(SubtitleCaptionStyle.standard.resolvedTextColor(cueColor: nil)) == [1, 1, 1, 1])
        let user = SubtitleCaptionStyle(textColor: .init(SubtitleColor(r: 0, g: 255, b: 0)), textOpacity: .init(0.5))
        #expect(components(user.resolvedTextColor(cueColor: cue)) == [0, 1, 0, 0.5])
    }

    @Test("background keeps the old look until the user changes it, and can be switched off")
    func backgroundResolution() {
        #expect(components(SubtitleCaptionStyle.standard.resolvedBackground!) == [0, 0, 0, 0.6])
        #expect(SubtitleCaptionStyle(backgroundOpacity: .init(0)).resolvedBackground == nil)
        let blue = SubtitleCaptionStyle(backgroundColor: .init(SubtitleColor(r: 0, g: 0, b: 255)), backgroundOpacity: .init(1))
        #expect(components(blue.resolvedBackground!) == [0, 0, 1, 1])
    }

    @Test("the window is off unless the user turned it on")
    func windowResolution() {
        #expect(SubtitleCaptionStyle.standard.resolvedWindow == nil)
        #expect(SubtitleCaptionStyle(windowOpacity: .init(0)).resolvedWindow == nil)
        #expect(components(SubtitleCaptionStyle(windowOpacity: .init(0.4)).resolvedWindow!) == [0, 0, 0, 0.4])
    }

    @Test("the user's font beats the cue's, and the size scales the frame-relative base")
    func fontAndSize() {
        let run = SubtitleTextRun(text: "x", color: nil, fontName: "Times-Roman")
        let cue = SubtitleFrameCompositor.font(for: run, baseSize: 40)
        let user = SubtitleFrameCompositor.font(for: run, baseSize: 40, style: SubtitleCaptionStyle(fontName: .init("Courier")))
        #expect(CTFontCopyPostScriptName(cue) as String == "Times-Roman")
        #expect(CTFontCopyPostScriptName(user) as String == "Courier")

        let yielding = SubtitleFrameCompositor.font(
            for: run, baseSize: 40, style: SubtitleCaptionStyle(fontName: .init("Courier", precedence: .yieldsToCue)))
        #expect(CTFontCopyPostScriptName(yielding) as String == "Times-Roman")
        let bare = SubtitleTextRun(text: "x", color: nil)
        let fallback = SubtitleFrameCompositor.font(
            for: bare, baseSize: 40, style: SubtitleCaptionStyle(fontName: .init("Courier", precedence: .yieldsToCue)))
        #expect(CTFontCopyPostScriptName(fallback) as String == "Courier")

        let base = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080)
        let big = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080, sizeScale: 2)
        #expect(big.fontSize == base.fontSize * 2)
        #expect(big.maxTextWidth == base.maxTextWidth)
    }

    // MARK: - Rendering

    /// Pixels with alpha above zero, and pixels that are exactly opaque white.
    private func pixelCounts(_ image: CGImage) -> (visible: Int, white: Int) {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return (-1, -1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var visible = 0, white = 0
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            if bytes[i + 3] > 0 { visible += 1 }
            if bytes[i] == 255 && bytes[i + 1] == 255 && bytes[i + 2] == 255 && bytes[i + 3] == 255 { white += 1 }
        }
        return (visible, white)
    }

    private let cue = SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Caption style"))

    @Test("a transparent background, a window and an outline change what is drawn")
    func overlayFollowsStyle() throws {
        func render(_ style: SubtitleCaptionStyle) throws -> (visible: Int, white: Int) {
            pixelCounts(try #require(SubtitleFrameCompositor.renderOverlay(
                for: [cue], frameWidth: 640, frameHeight: 360, style: style)))
        }
        let standard = try render(.standard)
        let bare = try render(SubtitleCaptionStyle(backgroundOpacity: .init(0)))
        let windowed = try render(SubtitleCaptionStyle(backgroundOpacity: .init(0), windowOpacity: .init(1)))
        let outlined = try render(SubtitleCaptionStyle(backgroundOpacity: .init(0), edgeStyle: .init(.uniform)))
        #expect(bare.visible > 0)
        #expect(bare.visible < standard.visible)
        #expect(windowed.visible > bare.visible)
        #expect(outlined.visible > bare.visible)
        // The outline sits behind the glyphs: it adds pixels around them and takes none from them.
        #expect(bare.white > 0)
        #expect(outlined.white == bare.white)
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
        let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source)
        try #require(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let input = try #require(source)
        CVPixelBufferLockBaseAddress(input, [])
        memset(CVPixelBufferGetBaseAddress(input), 0x40, CVPixelBufferGetBytesPerRow(input) * 180)
        CVPixelBufferUnlockBaseAddress(input, [])

        let compositor = SubtitleFrameCompositor(styleProvider: { .standard }, observesSystemStyle: false)
        compositor.update(cues: [cue], enabled: true, delaySeconds: 0)
        let before = frameBytes(compositor.composite(input, ptsSeconds: 1))
        #expect(before != frameBytes(input))
        #expect(before == frameBytes(compositor.composite(input, ptsSeconds: 1.1)))

        compositor.setStyle(SubtitleCaptionStyle(backgroundOpacity: .init(0), windowOpacity: .init(1)))
        let after = frameBytes(compositor.composite(input, ptsSeconds: 1.2))
        #expect(after != before)
    }

    @Test("the system style is read once, on the first enable, and never while disabled")
    func styleReadIsLazyAndSingle() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let reads = Counter()
        let compositor = SubtitleFrameCompositor(styleProvider: { _ = reads.bump(); return .standard },
                                                 observesSystemStyle: true)
        #expect(reads.value == 0)
        compositor.update(cues: [], enabled: false, delaySeconds: 0)
        #expect(reads.value == 0)
        compositor.update(cues: [], enabled: true, delaySeconds: 0)
        compositor.update(cues: [], enabled: true, delaySeconds: 0)
        #expect(reads.value == 1)
    }

    @Test("an overlay is never served in a style other than the current one")
    func cacheKeyedByStyle() throws {
        var source: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source)
        try #require(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let input = try #require(source)
        let compositor = SubtitleFrameCompositor(styleProvider: { .standard }, observesSystemStyle: false)
        compositor.update(cues: [cue], enabled: true, delaySeconds: 0)
        let standard = frameBytes(compositor.composite(input, ptsSeconds: 1))
        // Same cue set, different style: the cache entry from the first frame must not answer.
        compositor.setStyle(SubtitleCaptionStyle(backgroundOpacity: .init(0)))
        let bare = frameBytes(compositor.composite(input, ptsSeconds: 1.1))
        #expect(bare != standard)
        compositor.setStyle(.standard)
        #expect(frameBytes(compositor.composite(input, ptsSeconds: 1.2)) == standard)
    }

    @Test("a released observation no longer reaches its handler")
    func observationStops() {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock(); private var set = false
            func raise() { lock.lock(); set = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
        }
        let flag = Flag()
        var observation: SubtitleCaptionStyle.Observation? = SubtitleCaptionStyle.observeChanges(
            startingFrom: SubtitleCaptionStyle(backgroundOpacity: .init(0.123))) { _ in flag.raise() }
        observation = nil
        NotificationCenter.default.post(
            name: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String), object: nil)
        #expect(!flag.isSet)
        _ = observation
    }
}
