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
        static let radius: CGFloat = 24, row: CGFloat = 16, iconRadius: CGFloat = 11, viewfinder: CGFloat = 28
        static let icon: CGFloat = 36, touch: CGFloat = 44, shutter: CGFloat = 76, dock: CGFloat = 88
        static let codeWidth: CGFloat = 48, codeHeight: CGFloat = 60, codeRadius: CGFloat = 14
        static let ring: CGFloat = 26, hairline: CGFloat = 1, ringLine: CGFloat = 3, ringGap: Double = 0.04
        static let previewThumb: CGFloat = 56, flyThumb: CGFloat = 96, focus: CGFloat = 64, focusEnd: CGFloat = 44
        static let halo: CGFloat = 320, blur: CGFloat = 80, haloOffset: CGFloat = 140, thumbPixels = 480
        static let aspect: CGFloat = 4 / 3, mark: CGFloat = 44, markRatio: CGFloat = 0.24
        static let flightHeight: CGFloat = 180, dockOffset: CGFloat = 12, maxText: CGFloat = 0.8
    }
    enum CaptureLayout {
        // Portrait presentation of the full 4:3 camera sensor, with no cropping.
        static func preview(in available: CGSize) -> CGSize {
            let height = max(0, available.height - 44 - 12 - 12 - 44 - 40)
            let width = max(0, min(available.width - 24, height * 3 / 4))
            return CGSize(width: width, height: width * 4 / 3)
        }
    }
    enum TypeStyle {
        static let title = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let number = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
        static let heading = Font.headline, body = Font.subheadline, caption = Font.footnote, micro = Font.caption2
    }
    enum Motion {
        static let state = Animation.spring(response: 0.38, dampingFraction: 0.78), press = Animation.snappy(duration: 0.25), page = Animation.spring(response: 0.38, dampingFraction: 0.78)
        static let period: Double = 20, drift: Float = 0.04, interval: Double = 1, flash: Double = 0.06, flight: Double = 0.6
        static let pressScale: CGFloat = 0.97, shutterScale: CGFloat = 0.92, arrival: CGFloat = 1.15, entering: CGFloat = 0.9
        static let tilt: Double = -8, ringStart: Double = -90
        static let dismissDistance: CGFloat = 120
        static let fade = Animation.easeInOut(duration: 0.2), innerShutter: CGFloat = 0.84
    }
    private static let dateWithTime: DateFormatter = makeDateFormatter("M月d日 HH:mm")
    private static let dateWithoutTime: DateFormatter = makeDateFormatter("M月d日 EEEE")
    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent; formatter.dateFormat = format
        return formatter
    }
    static func date(_ date: Date, time: Bool = true) -> String { (time ? dateWithTime : dateWithoutTime).string(from: date) }

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
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: SnapTheme.Layout.hairline).allowsHitTesting(false))
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
            .contentShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.row)).opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed && !reduceMotion ? SnapTheme.Motion.pressScale : 1)
            .animation(reduceMotion ? .easeOut : SnapTheme.Motion.press, value: configuration.isPressed)
    }
}

// Full visible labels are touchable; compact controls keep their layout, never their hit area.
struct SnapTouchStyle: ButtonStyle {
    var radius: CGFloat = SnapTheme.Layout.row
    var hitSlop: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: SnapTheme.Layout.touch, minHeight: SnapTheme.Layout.touch)
            .contentShape(RoundedRectangle(cornerRadius: radius).inset(by: -hitSlop))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? SnapTheme.Motion.pressScale : 1)
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder func snapSelection(id: String, namespace: Namespace.ID, reduced: Bool) -> some View {
        if reduced { self } else { self.matchedGeometryEffect(id: id, in: namespace) }
    }
}
struct SnapSegments: View {
    let values: [String], titles: [String]
    @Binding var selection: String
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Button { selection = values[index] } label: {
                    Text(titles[index]).font(SnapTheme.TypeStyle.caption).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selection == values[index] ? .white : .primary)
                        .background { if selection == values[index] { Capsule().fill(SnapTheme.gradient).snapSelection(id: "selection", namespace: highlight, reduced: reduceMotion).allowsHitTesting(false) } }
                }.buttonStyle(SnapTouchStyle()).accessibilityAddTraits(selection == values[index] ? [.isSelected] : [])
            }
        }.background(SnapTheme.waiting.opacity(0.12), in: Capsule()).animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: selection)
    }
}
struct SnapToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(isOn ? SnapTheme.blue : SnapTheme.waiting.opacity(0.4)).frame(width: 44, height: 26)
                    .overlay(alignment: isOn ? .trailing : .leading) { Circle().fill(.white).frame(width: 22, height: 22).padding(2).allowsHitTesting(false) }
            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(SnapTouchStyle()).accessibilityValue(isOn ? "已开启" : "已关闭")
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: isOn)
    }
}
