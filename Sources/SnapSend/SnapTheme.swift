import SwiftUI

// Shared visual language for the classroom workspace and its camera companion.
enum SnapTheme {
    static let blue = Color(red: 0.16, green: 0.40, blue: 0.98)
    static let violet = Color(red: 0.43, green: 0.25, blue: 0.94)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct SnapBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark
            ? [Color(red: 0.075, green: 0.085, blue: 0.13), Color(red: 0.10, green: 0.11, blue: 0.17)]
            : [Color(red: 0.95, green: 0.96, blue: 0.985), Color(red: 0.97, green: 0.97, blue: 0.99)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea().allowsHitTesting(false)
    }
}

struct SnapMark: View {
    var size: CGFloat = 44
    #if os(macOS)
    private static let mark: NSImage? = Bundle.main.url(forResource: "SnapMark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    #endif
    var body: some View {
        #if os(macOS)
        if let image = Self.mark {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        }
        #else
        Image("SnapMark").resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        #endif
    }
}

struct SnapSurface: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        content
            .background(AnyShapeStyle(.background), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 8, x: 0, y: 3)
    }
}

struct SnapGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *), !opaque {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content.modifier(SnapSurface())
        }
    }
}

struct SnapPrimaryButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.horizontal, 18).padding(.vertical, 13)
            .foregroundStyle(.white).background(SnapTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: SnapTheme.blue.opacity(enabled ? 0.22 : 0), radius: 12, y: 5)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
