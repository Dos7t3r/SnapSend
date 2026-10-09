import SwiftUI
import AppKit
import SnapSendCore

struct MenuBarPanel: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack { SnapMark(size: Aurora.Space.icon); Text("SnapSend").font(Aurora.TypeStyle.heading); Spacer(); Image(systemName: model.menuSymbol).foregroundStyle(model.menuColor) }
            status("手机", ready: model.usbConnected, detail: model.usbConnected ? "USB 已连接" : "插线并解锁")
            status("扩展", ready: model.browserConnected, detail: model.browserConnected ? "桥接已连接" : "打开 Chrome 扩展")
            status("目标", ready: model.chatMatchesClass, detail: model.targetSection?.name ?? "收件箱")
            status("发送", ready: model.autoSend, detail: model.autoSend ? "自动发送" : "暂停，仍保存原图")
            Menu("更换目标") { Button("收件箱") { model.chooseSection(nil) }; ForEach((model.catalog.sections ?? []).filter { section in model.catalog.courses.contains { $0.id == section.courseID && $0.archived != true } }) { section in Button(section.name) { model.chooseSection(section.id) } } }
            ForEach(Array(model.records.suffix(3).reversed())) { photo in HStack { Text(photo.receivedAt.formatted(date: .omitted, time: .shortened)); Spacer(); Text(model.stageOf(photo) == .sent ? "已发送" : "已保存") }.font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary) }
            Button("打开 SnapSend") { openWindow(id: "workspace"); NSApplication.shared.activate() }.auroraButton(primary: true)
        }.padding(Aurora.Space.card).frame(width: Aurora.Space.menu).preferredColorScheme(.dark)
    }
    private func status(_ title: String, ready: Bool, detail: String) -> some View { HStack { Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Aurora.Colors.success : Aurora.Colors.queued); Text(title); Spacer(); Text(detail).foregroundStyle(Aurora.Colors.secondary).lineLimit(1) }.font(Aurora.TypeStyle.caption) }
}
