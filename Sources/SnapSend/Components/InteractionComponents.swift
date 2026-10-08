import SwiftUI
import AppKit

/// The label, padding and hover surface share exactly the same hit-test shape.
struct PressableStyle: PrimitiveButtonStyle {
    var radius: CGFloat = Aurora.Space.rowRadius
    var inset: CGFloat = 0
    var row = false
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        PressableActivation(configuration: configuration, radius: radius, inset: inset, row: row, filled: filled)
    }
}
private struct PressableActivation: View {
    var configuration: PrimitiveButtonStyleConfiguration
    var radius: CGFloat, inset: CGFloat
    var row: Bool, filled: Bool
    @State private var activation = 0
    @Environment(\.auroraReduceMotion) private var reduceMotion
    var body: some View {
        Button(role: configuration.role) { configuration.trigger(); activation += 1 } label: {
            configuration.label.symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : activation)
        }.buttonStyle(PressableVisualStyle(radius: radius, inset: inset, row: row, filled: filled))
    }
}
private struct PressableVisualStyle: ButtonStyle {
    var radius: CGFloat, inset: CGFloat
    var row: Bool, filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(label: configuration.label, pressed: configuration.isPressed, radius: radius, inset: inset, row: row, filled: filled)
    }
}
private struct PressableBody<Label: View>: View {
    var label: Label
    var pressed: Bool
    var radius: CGFloat, inset: CGFloat
    var row: Bool, filled: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.auroraReduceMotion) private var reduceMotion
    @State private var hover = false
    var body: some View {
        label.padding(inset).frame(minWidth: 28, minHeight: 28)
            .background { if filled { RoundedRectangle(cornerRadius: radius).fill(Aurora.Colors.selected).allowsHitTesting(false) } }
            .background(.white.opacity(enabled && hover ? Aurora.Alpha.hover : 0), in: RoundedRectangle(cornerRadius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(pressed && !reduceMotion ? (row ? Aurora.Motion.rowScale : Aurora.Motion.buttonScale) : 1)
            .onHover { hover = $0 }
            .animation(Aurora.Motion.highlight, value: hover)
            .animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: pressed)
            .handPointer(enabled: enabled)
    }
}
struct ClickableRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        Button(action: action) { content().frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(PressableStyle(row: true))
    }
}
private struct HandPointer: ViewModifier {
    var enabled: Bool
    @State private var pushed = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.pointerStyle(enabled ? .link : nil) }
        else {
            content.onHover { inside in
                if inside && enabled && !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside { restore() }
            }.onChange(of: enabled) { _, value in if !value { restore() } }.onDisappear { restore() }
        }
    }
    private func restore() { if pushed { NSCursor.pop(); pushed = false } }
}
extension View {
    func selectionBounce(_ selected: Bool) -> some View { modifier(SelectionBounce(selected: selected)) }
    func handPointer(enabled: Bool = true) -> some View { modifier(HandPointer(enabled: enabled)) }
    func menuHitArea() -> some View { modifier(MenuHitSurface()) }
    func cardEntrance(_ index: Int) -> some View { modifier(CardEntrance(index: index)) }
    func animatedRows<Value: Equatable>(_ value: Value) -> some View { modifier(RowMotion(value: value)) }
}
private struct CardEntrance: ViewModifier {
    var index: Int
    @State private var appeared = false
    @Environment(\.auroraReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : Aurora.Motion.pageIn)
            .onAppear { withAnimation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state.delay(min(Double(index) * Aurora.Motion.stagger, Aurora.Motion.maximumDelay))) { appeared = true } }
    }
}
private struct RowMotion<Value: Equatable>: ViewModifier {
    var value: Value
    @Environment(\.auroraReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: Aurora.Motion.rowIn).combined(with: .opacity).combined(with: .scale(scale: Aurora.Motion.insertionScale)), removal: .opacity))
            .animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: value)
    }
}
struct SpringToggle: ToggleStyle {
    @Environment(\.auroraReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        ClickableRow { configuration.isOn.toggle() } content: {
            HStack {
                configuration.label
                Spacer()
                Capsule().fill(configuration.isOn ? Aurora.Colors.success : Aurora.Colors.queued.opacity(0.5))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(.white).frame(width: 18, height: 18).padding(2).allowsHitTesting(false) }
                    .animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: configuration.isOn)
            }
        }.accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

private struct SelectionBounce: ViewModifier {
    var selected: Bool
    @State private var trigger = 0
    @Environment(\.auroraReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.phaseAnimator([CGFloat(1), Aurora.Motion.iconScale, CGFloat(1)], trigger: trigger) { view, scale in
            view.scaleEffect(reduceMotion ? 1 : scale)
        } animation: { _ in Aurora.Motion.iconBounce }
            .onChange(of: selected) { _, value in if value && !reduceMotion { trigger += 1 } }
    }
}

private struct MenuHitSurface: ViewModifier {
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.frame(minWidth: 28, minHeight: 28)
            .background(.white.opacity(enabled && hover ? Aurora.Alpha.hover : 0), in: RoundedRectangle(cornerRadius: Aurora.Space.iconRadius))
            .contentShape(RoundedRectangle(cornerRadius: Aurora.Space.iconRadius))
            .onHover { hover = $0 }.animation(Aurora.Motion.highlight, value: hover).handPointer(enabled: enabled)
    }
}
struct StringSegments: View {
    var options: [(String, String)]
    @Binding var value: String
    @Namespace private var selection
    @Environment(\.auroraReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: Aurora.Space.tiny) {
            ForEach(options, id: \.0) { item in
                Button { withAnimation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state) { value = item.0 } } label: {
                    Text(item.1).frame(maxWidth: .infinity, alignment: .leading).padding(Aurora.Space.small)
                        .background { if value == item.0 { RoundedRectangle(cornerRadius: Aurora.Space.rowRadius).fill(Aurora.Colors.selected).matchedGeometryEffect(id: "selection", in: selection).allowsHitTesting(false) } }
                }.buttonStyle(PressableStyle(row: true))
            }
        }
    }
}
