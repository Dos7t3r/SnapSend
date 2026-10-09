import SwiftUI

// Shared by both native targets. All companion layout, palette and motion choices live here.
enum SnapTheme {
    static let blue = color(0x4C7DFF), violet = color(0x7C6CFF)
    static let local = color(0xFF9F43), success = color(0x3DDC97), failure = color(0xFF5D6C), waiting = color(0x8A8F9C), cyan = color(0x2EE6D6)
    static let dark = color(0x070B16), light = color(0xF4F6FB), text = color(0xF2F3F7), ink = color(0x12141F)
    static let course = [blue, color(0xFF8A5B), success, color(0xC471ED), color(0xFFC857), cyan]
    static let darkMesh = [color(0x0A1230), color(0x1B1250), color(0x0B3A4A), color(0x2A1060)]
    static let lightMesh = [color(0xDCE6FF), color(0xE8DEFF), color(0xD5F5F0)]
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static func color(_ hex: UInt32) -> Color { Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
    enum Alpha {
        static let soft = 0.08, icon = 0.12, active = 0.2, dim = 0.4, secondary = 0.55, flash = 0.7, viewfinder = 0.75
    }
    enum Layout {
        static let page: CGFloat = 20, gap: CGFloat = 14, card: CGFloat = 18, small: CGFloat = 8, tiny: CGFloat = 4
        static let radius: CGFloat = 24, row: CGFloat = 16, iconRadius: CGFloat = 11, viewfinder: CGFloat = 32
        static let icon: CGFloat = 36, touch: CGFloat = 44, shutter: CGFloat = 72, dock: CGFloat = 88
        static let codeWidth: CGFloat = 48, codeHeight: CGFloat = 60, codeRadius: CGFloat = 14
        static let ring: CGFloat = 26, hairline: CGFloat = 1, ringLine: CGFloat = 3, ringGap: Double = 0.04
        static let previewThumb: CGFloat = 52, flyThumb: CGFloat = 96, focus: CGFloat = 64, focusEnd: CGFloat = 44
        static let halo: CGFloat = 320, blur: CGFloat = 80, haloOffset: CGFloat = 140, thumbPixels = 480
        static let aspect: CGFloat = 4 / 3, mark: CGFloat = 44, markRatio: CGFloat = 0.24
        static let flightHeight: CGFloat = 180, dockOffset: CGFloat = 12, maxText: CGFloat = 0.8
    }
    enum TypeStyle {
        static let title = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let number = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
        static let heading = Font.headline, body = Font.subheadline, caption = Font.footnote, micro = Font.caption2
    }
    enum Motion {
        static let state = Animation.spring(duration: 0.45, bounce: 0.25), press = Animation.snappy(duration: 0.25), page = Animation.smooth(duration: 0.6)
        static let period: Double = 20, drift: Float = 0.04, interval: Double = 1, flash: Double = 0.06, flight: Double = 0.6
        static let pressScale: CGFloat = 0.97, shutterScale: CGFloat = 0.92, arrival: CGFloat = 1.15, entering: CGFloat = 0.9
        static let tilt: Double = -8, ringStart: Double = -90
        static let dismissDistance: CGFloat = 120
    }
    static func date(_ date: Date, time: Bool = true) -> String {
        date.formatted(time ? .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")) : .dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN")))
    }
}

struct SnapBackdrop: View {
    var paused = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: SnapTheme.Motion.interval, paused: paused || phase != .active || reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate / SnapTheme.Motion.period * 2 * .pi
            let palette = scheme == .dark ? SnapTheme.darkMesh : SnapTheme.lightMesh
            ZStack {
                scheme == .dark ? SnapTheme.dark : SnapTheme.light
                if #available(macOS 15, iOS 18, *) {
                    MeshGradient(width: 3, height: 3, points: [SIMD2<Float>(0,0), SIMD2<Float>(0.5,0), SIMD2<Float>(1,0), SIMD2<Float>(0,0.5), SIMD2<Float>(0.5 + SnapTheme.Motion.drift * Float(sin(t)),0.5 + SnapTheme.Motion.drift * Float(cos(t))), SIMD2<Float>(1,0.5), SIMD2<Float>(0,1), SIMD2<Float>(0.5,1), SIMD2<Float>(1,1)], colors: [palette[0], palette[1], palette[0], palette[2], scheme == .dark ? SnapTheme.dark : SnapTheme.light, palette.last!, palette[0], palette[1], palette[2]])
                } else {
                    LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(SnapTheme.cyan.opacity(0.2)).frame(width: SnapTheme.Layout.halo).blur(radius: SnapTheme.Layout.blur).offset(x: -SnapTheme.Layout.haloOffset, y: -SnapTheme.Layout.haloOffset)
                    Circle().fill(SnapTheme.violet.opacity(0.2)).frame(width: SnapTheme.Layout.halo).blur(radius: SnapTheme.Layout.blur).offset(x: SnapTheme.Layout.haloOffset, y: SnapTheme.Layout.haloOffset)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct SnapMark: View {
    var size: CGFloat = SnapTheme.Layout.mark
    #if os(macOS)
    private static let mark: NSImage? = Bundle.main.url(forResource: "SnapMark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    #endif
    var body: some View {
        #if os(macOS)
        if let image = Self.mark { Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * SnapTheme.Layout.markRatio)) }
        #else
        Image("SnapMark").resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * SnapTheme.Layout.markRatio))
        #endif
    }
}
struct SnapSurface: ViewModifier {
    var radius: CGFloat = SnapTheme.Layout.radius
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        content.background(opaque ? AnyShapeStyle(scheme == .dark ? SnapTheme.darkMesh[0] : SnapTheme.light) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: SnapTheme.Layout.hairline))
    }
}
struct SnapGlass: ViewModifier {
    var radius: CGFloat = SnapTheme.Layout.radius
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), !opaque { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius)) }
        else { content.modifier(SnapSurface(radius: radius)) }
    }
}
extension View {
    @ViewBuilder func snapGlassGroup() -> some View { if #available(macOS 26, iOS 26, *) { GlassEffectContainer(spacing: SnapTheme.Layout.small) { self } } else { self } }
}
struct SnapPrimaryButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(SnapTheme.TypeStyle.heading).padding(.horizontal, SnapTheme.Layout.card).padding(.vertical, SnapTheme.Layout.gap)
            .foregroundStyle(.white).background(SnapTheme.gradient, in: RoundedRectangle(cornerRadius: SnapTheme.Layout.row))
            .opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed && !reduceMotion ? SnapTheme.Motion.pressScale : 1)
            .animation(reduceMotion ? .easeOut : SnapTheme.Motion.press, value: configuration.isPressed)
    }
}
