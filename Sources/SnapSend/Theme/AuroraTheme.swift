import SwiftUI
import AppKit

enum Aurora {
    enum Colors {
        static let white = Color.white
        static let background = Color(hex: 0x070B16)
        static let primary = Color(hex: 0xF2F3F7)
        static let secondary = Color.white.opacity(0.55)
        static let tertiary = Color.white.opacity(0.35)
        static let phone = Color(hex: 0xFF9F43), bridge = Color(hex: 0x2EE6D6)
        static let target = Color(hex: 0x8B7CFF), success = Color(hex: 0x3DDC97)
        static let error = Color(hex: 0xFF5D6C), queued = Color(hex: 0x8A8F9C)
        static let blue = Color(hex: 0x4C7DFF)
        static let selected = LinearGradient(colors: [blue, Color(hex: 0x7C6CFF)], startPoint: .leading, endPoint: .trailing)
        static let course = [blue, Color(hex: 0xFF8A5B), success, Color(hex: 0xC471ED), Color(hex: 0xFFC857), bridge]
        static let mesh = [Color(hex: 0x0A1230), Color(hex: 0x1B1250), Color(hex: 0x0B3A4A), Color(hex: 0x2A1060)]
    }
    enum Alpha {
        static let faint = 0.04, hover = 0.05, icon = 0.12, active = 0.24, strong = 0.16, label = 0.06
        static let line = 0.45, dim = 0.2, ring = 0.85, outline = 0.25
    }
    enum Space {
        static let page: CGFloat = 28, gap: CGFloat = 16, card: CGFloat = 20, inset: CGFloat = 12
        static let small: CGFloat = 8, tiny: CGFloat = 4, row: CGFloat = 60, nav: CGFloat = 40
        static let sidebar: CGFloat = 232, pipeline: CGFloat = 190, node: CGFloat = 56, thumb: CGFloat = 44, icon: CGFloat = 36
        static let historyShare: CGFloat = 0.6
        static let columns: CGFloat = 4, tileHeight: CGFloat = 136
        static let menu: CGFloat = 300, minimumWidth: CGFloat = 960, minimumHeight: CGFloat = 640
        static let halo: CGFloat = 360, haloBlur: CGFloat = 100, haloOffset: CGFloat = 180
        static let thumbnailPixels = 160
        static let nodes: CGFloat = 4, links: CGFloat = 3, pipelineGaps: CGFloat = 6, linkDivisor: CGFloat = 8
        static let travellingThumb: CGFloat = 24, travellingY: CGFloat = 8
        static let radius: CGFloat = 24, sidebarRadius: CGFloat = 28, rowRadius: CGFloat = 14, iconRadius: CGFloat = 11, thumbRadius: CGFloat = 10
        static let hairline: CGFloat = 1, line: CGFloat = 2, bar: CGFloat = 4, hover: CGFloat = 2
        static let editor: CGFloat = 480, preview: CGFloat = 780, previewHeight: CGFloat = 540
    }
    enum TypeStyle {
        static let title = Font.system(size: 34, weight: .bold, design: .rounded)
        static let number = Font.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit()
        static let heading = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15)
        static let caption = Font.system(size: 13)
        static let micro = Font.system(size: 11, weight: .medium)
    }
    enum Motion {
        static let state = Animation.spring(duration: 0.45, bounce: 0.25)
        static let hover = Animation.snappy(duration: 0.25)
        static let page = Animation.smooth(duration: 0.6)
        static let pressedScale: CGFloat = 0.97
        static let period: Double = 20, drift: Float = 0.04, frameInterval: Double = 1
        static let flash: Double = 0.6, arrivalScale: CGFloat = 1.15
    }
    static func courseColor(_ index: Int) -> Color { Colors.course[abs(index) % Colors.course.count] }
}
private extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var active
    @State private var appActive = false
    var body: some View {
        // No free-running timer when the window loses focus. Reduce Motion uses the same static composition.
        TimelineView(.animation(minimumInterval: Aurora.Motion.frameInterval, paused: reduceMotion || !appActive || active != .key)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate / Aurora.Motion.period * 2 * .pi
            ZStack {
                Aurora.Colors.background
                if #available(macOS 15, *) {
                    MeshGradient(width: 3, height: 3, points: [
                        SIMD2<Float>(0,0), SIMD2<Float>(0.5,0), SIMD2<Float>(1,0),
                        SIMD2<Float>(0,0.5), SIMD2<Float>(0.5 + Aurora.Motion.drift * Float(sin(phase)),0.5 + Aurora.Motion.drift * Float(cos(phase))), SIMD2<Float>(1,0.5),
                        SIMD2<Float>(0,1), SIMD2<Float>(0.5,1), SIMD2<Float>(1,1)],
                        colors: [Aurora.Colors.mesh[0], Aurora.Colors.mesh[1], Aurora.Colors.mesh[0], Aurora.Colors.mesh[2], Aurora.Colors.background, Aurora.Colors.mesh[3], Aurora.Colors.mesh[0], Aurora.Colors.mesh[1], Aurora.Colors.mesh[2]])
                } else {
                    LinearGradient(colors: Aurora.Colors.mesh, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Aurora.Colors.bridge.opacity(Aurora.Alpha.dim)).frame(width: Aurora.Space.halo).blur(radius: Aurora.Space.haloBlur).offset(x: -Aurora.Space.haloOffset, y: -Aurora.Space.haloOffset)
                    Circle().fill(Aurora.Colors.target.opacity(Aurora.Alpha.dim)).frame(width: Aurora.Space.halo).blur(radius: Aurora.Space.haloBlur).offset(x: Aurora.Space.haloOffset, y: Aurora.Space.haloOffset)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false)
            .onAppear { appActive = NSApplication.shared.isActive }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = Aurora.Space.radius
    var tint: Color? = nil
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder private func surface<V: View>(_ content: V) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(tint.map { .regular.tint($0.opacity(0.12)) } ?? .regular, in: .rect(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: Aurora.Space.hairline))
        }
    }
    func body(content: Content) -> some View {
        surface(content.background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: radius))).overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(hover ? 0.18 : 0.08), lineWidth: Aurora.Space.hairline))
            .offset(y: hover && !reduceMotion ? -Aurora.Space.hover : 0).onHover { hover = $0 }.animation(reduceMotion ? nil : Aurora.Motion.hover, value: hover)
    }
}
extension View {
    func glassCard(cornerRadius: CGFloat = Aurora.Space.radius, tint: Color? = nil) -> some View { modifier(GlassCard(radius: cornerRadius, tint: tint)) }
    @ViewBuilder func auroraGlassGroup() -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: Aurora.Space.small) { self } } else { self }
    }
    @ViewBuilder func auroraButton(primary: Bool = false) -> some View {
        if #available(macOS 26, *) { if primary { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) } }
        else { if primary { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) } }
    }
}

struct AuroraInlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, Aurora.Space.inset).padding(.vertical, Aurora.Space.small)
            .background(Aurora.Colors.blue.opacity(configuration.isPressed ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: Aurora.Space.iconRadius))
            .scaleEffect(configuration.isPressed ? Aurora.Motion.pressedScale : 1).animation(Aurora.Motion.hover, value: configuration.isPressed)
    }
}
