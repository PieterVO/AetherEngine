import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

/// The user's system caption style (Settings > Accessibility > Subtitles & Captioning), for the
/// software host's text rendering, which has no AVKit legible output to apply it for it.
///
/// Every field that the user has actually overridden is non-nil; nil means "no preference", and
/// the renderer keeps the cue's own styling (an SRT `<font color>`, an ASS `\fn`) or the engine's
/// default look. That mirrors the `MACaptionAppearanceBehavior` split: `UseValue` overrides the
/// content, `UseContentIfAvailable` yields to it. A system with nothing customised therefore reads
/// as `.standard`, and renders exactly as before this type existed.
///
/// Bitmap subtitles (PGS, DVB, VobSub) are pictures and are never restyled.
public struct SubtitleCaptionStyle: Sendable, Equatable {

    /// Text edge treatment, in the system's own vocabulary.
    public enum EdgeStyle: Sendable, Equatable {
        case none, raised, depressed, uniform, dropShadow
    }

    /// Family name or PostScript name of the font the user chose; nil keeps the cue's or the default.
    public var fontName: String?
    /// The user's character size relative to the default, 1 when untouched. Applied on top of the
    /// frame-relative base size, so the text stays proportionate at any resolution.
    public var sizeScale: Double
    public var textColor: SubtitleColor?
    public var textOpacity: Double?
    public var backgroundColor: SubtitleColor?
    public var backgroundOpacity: Double?
    /// The window is the rectangle behind the whole caption block, behind the per-line background.
    public var windowColor: SubtitleColor?
    public var windowOpacity: Double?
    public var edgeStyle: EdgeStyle?

    public init(fontName: String? = nil, sizeScale: Double = 1,
                textColor: SubtitleColor? = nil, textOpacity: Double? = nil,
                backgroundColor: SubtitleColor? = nil, backgroundOpacity: Double? = nil,
                windowColor: SubtitleColor? = nil, windowOpacity: Double? = nil,
                edgeStyle: EdgeStyle? = nil) {
        self.fontName = fontName
        self.sizeScale = sizeScale
        self.textColor = textColor
        self.textOpacity = textOpacity
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.windowColor = windowColor
        self.windowOpacity = windowOpacity
        self.edgeStyle = edgeStyle
    }

    /// No user preference: the engine's default look.
    public static let standard = SubtitleCaptionStyle()

    /// Default line background when the user has not chosen one: the engine's long-standing look.
    static let defaultBackgroundOpacity = 0.6

    // MARK: - Resolved values

    /// Text colour for a run: the user's choice beats the cue's own, the cue's beats white.
    func resolvedTextColor(cueColor: SubtitleColor?) -> CGColor {
        let color = textColor ?? cueColor ?? SubtitleColor(r: 255, g: 255, b: 255)
        return Self.cgColor(color, opacity: textOpacity ?? 1)
    }

    /// Line background; nil when the user has made it fully transparent.
    var resolvedBackground: CGColor? {
        let opacity = backgroundOpacity ?? Self.defaultBackgroundOpacity
        guard opacity > 0 else { return nil }
        return Self.cgColor(backgroundColor ?? SubtitleColor(r: 0, g: 0, b: 0), opacity: opacity)
    }

    /// Caption window; nil unless the user turned it on (the default has none).
    var resolvedWindow: CGColor? {
        guard let opacity = windowOpacity, opacity > 0 else { return nil }
        return Self.cgColor(windowColor ?? SubtitleColor(r: 0, g: 0, b: 0), opacity: opacity)
    }

    private static func cgColor(_ color: SubtitleColor, opacity: Double) -> CGColor {
        CGColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255, alpha: CGFloat(min(max(opacity, 0), 1)))
    }

    // MARK: - System values

    /// What MediaAccessibility reports, reduced to plain values so the mapping to a style can be
    /// tested without the user's settings. A property is `overridden` when the system says its
    /// value should win over the content (`UseValue`).
    struct SystemValues: Equatable {
        struct Override<Value: Equatable>: Equatable {
            var value: Value
            var overridden: Bool
        }
        var fontName: Override<String?>
        var sizeScale: Double
        var textColor: Override<SubtitleColor>
        var textOpacity: Override<Double>
        var backgroundColor: Override<SubtitleColor>
        var backgroundOpacity: Override<Double>
        var windowColor: Override<SubtitleColor>
        var windowOpacity: Override<Double>
        var edgeStyle: Override<EdgeStyle?>
    }

    init(_ system: SystemValues) {
        func chosen<V>(_ o: SystemValues.Override<V>) -> V? { o.overridden ? o.value : nil }
        self.init(fontName: chosen(system.fontName) ?? nil,
                  sizeScale: system.sizeScale.isFinite && system.sizeScale > 0 ? system.sizeScale : 1,
                  textColor: chosen(system.textColor), textOpacity: chosen(system.textOpacity),
                  backgroundColor: chosen(system.backgroundColor),
                  backgroundOpacity: chosen(system.backgroundOpacity),
                  windowColor: chosen(system.windowColor), windowOpacity: chosen(system.windowOpacity),
                  edgeStyle: chosen(system.edgeStyle) ?? nil)
    }

    nonisolated static func edgeStyle(forSystem raw: Int) -> EdgeStyle? {
        switch MACaptionAppearanceTextEdgeStyle(rawValue: raw) {
        case .none?: return EdgeStyle.none
        case .raised?: return .raised
        case .depressed?: return .depressed
        case .uniform?: return .uniform
        case .dropShadow?: return .dropShadow
        default: return nil   // undefined: leave it to the default look
        }
    }

    /// The user's current style. Reads the system on every call, so it is cheap to call again after
    /// `observeChanges` fires but not meant for a per-frame loop.
    public static func current() -> SubtitleCaptionStyle {
        SubtitleCaptionStyle(systemValues())
    }

    private static func systemValues() -> SystemValues {
        let domain = MACaptionAppearanceDomain.user
        func override(_ behavior: MACaptionAppearanceBehavior) -> Bool { behavior == .useValue }
        func color(_ read: (MACaptionAppearanceDomain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> Unmanaged<CGColor>)
            -> SystemValues.Override<SubtitleColor> {
            var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
            let cg = read(domain, &behavior).takeRetainedValue()
            return .init(value: subtitleColor(cg), overridden: override(behavior))
        }
        func opacity(_ read: (MACaptionAppearanceDomain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> CGFloat)
            -> SystemValues.Override<Double> {
            var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
            let value = read(domain, &behavior)
            return .init(value: Double(value), overridden: override(behavior))
        }

        var fontBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, &fontBehavior, .default)
            .takeRetainedValue()
        let font = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String

        var edgeBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let edge = MACaptionAppearanceGetTextEdgeStyle(domain, &edgeBehavior)

        return SystemValues(
            fontName: .init(value: font, overridden: override(fontBehavior)),
            sizeScale: Double(MACaptionAppearanceGetRelativeCharacterSize(domain, nil)),
            textColor: color(MACaptionAppearanceCopyForegroundColor),
            textOpacity: opacity(MACaptionAppearanceGetForegroundOpacity),
            backgroundColor: color(MACaptionAppearanceCopyBackgroundColor),
            backgroundOpacity: opacity(MACaptionAppearanceGetBackgroundOpacity),
            windowColor: color(MACaptionAppearanceCopyWindowColor),
            windowOpacity: opacity(MACaptionAppearanceGetWindowOpacity),
            edgeStyle: .init(value: edgeStyle(forSystem: edge.rawValue), overridden: override(edgeBehavior)))
    }

    private static func subtitleColor(_ color: CGColor) -> SubtitleColor {
        let rgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) } ?? color
        let c = rgb.components ?? []
        func byte(_ i: Int) -> UInt8 { i < c.count ? UInt8((min(max(c[i], 0), 1) * 255).rounded()) : 255 }
        // A grey-scale colour carries one component; the three channels are then the same.
        return c.count >= 3 ? SubtitleColor(r: byte(0), g: byte(1), b: byte(2))
                            : SubtitleColor(r: byte(0), g: byte(0), b: byte(0))
    }

    // MARK: - Change observation

    /// Token for `observeChanges`; the observation ends when it is released.
    public final class Observation: @unchecked Sendable {
        private let tokens: [NSObjectProtocol]
        fileprivate init(tokens: [NSObjectProtocol]) { self.tokens = tokens }
        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
                #if os(macOS)
                DistributedNotificationCenter.default().removeObserver(token)
                #endif
            }
        }
    }

    /// Calls `handler` with the new style whenever the user changes a caption setting. Fires only
    /// when the resolved style differs from the last one delivered, so a settings write that
    /// touches nothing this type reads is silent. Hold the returned token for as long as updates
    /// are wanted.
    public static func observeChanges(_ handler: @escaping @Sendable (SubtitleCaptionStyle) -> Void) -> Observation {
        let last = LastStyle(current())
        let name = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)
        let fire: @Sendable (Notification) -> Void = { _ in
            let style = current()
            if last.replace(with: style) { handler(style) }
        }
        var tokens = [NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil, using: fire)]
        #if os(macOS)
        // The setting is changed in another process, and macOS delivers it on the distributed centre.
        tokens.append(DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil, using: fire))
        #endif
        return Observation(tokens: tokens)
    }

    private final class LastStyle: @unchecked Sendable {
        private let lock = NSLock()
        private var style: SubtitleCaptionStyle
        init(_ style: SubtitleCaptionStyle) { self.style = style }
        /// True when `new` differs from what was held.
        func replace(with new: SubtitleCaptionStyle) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard new != style else { return false }
            style = new
            return true
        }
    }
}
