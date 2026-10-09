import SwiftUI
import AppKit
import SnapSendCore

struct StatusNode: View {
    var symbol: String, title: String, detail: String
    var color: Color, ready: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: Aurora.Space.small) {
                Image(systemName: symbol).font(Aurora.TypeStyle.heading).foregroundStyle(ready ? color : Aurora.Colors.tertiary)
                    .frame(width: Aurora.Space.node, height: Aurora.Space.node)
                    .background(color.opacity(ready ? Aurora.Alpha.strong : Aurora.Alpha.faint), in: Circle())
                    .overlay(Circle().stroke(color.opacity(ready ? Aurora.Alpha.ring : Aurora.Alpha.outline), lineWidth: Aurora.Space.line))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, value: ready)
                Text(title).font(Aurora.TypeStyle.body).foregroundStyle(Aurora.Colors.primary)
                Text(detail).font(Aurora.TypeStyle.micro).foregroundStyle(ready ? color : Aurora.Colors.secondary).lineLimit(1)
                if !ready { Text("修复 ›").font(Aurora.TypeStyle.micro).foregroundStyle(color) }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).help(detail)
    }
}
struct PipelineView: View {
    @ObservedObject var model: WorkspaceModel
    var configure: () -> Void
    @State private var flash = false
    @State private var travellingID: UUID?
    @State private var nodeIndex = 1
    @State private var arrival = false
    @State private var animationTask: Task<Void, Never>?
    private var hasFailure: Bool { model.deliveries.contains { [.failed, .uncertain].contains($0.state) } }
    private var transferState: DeliveryState? { model.deliveries.first { $0.id == travellingID }?.state }
    private var stateSignature: String { model.deliveries.map { $0.id.uuidString + $0.state.rawValue }.joined() }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack { Text("照片的旅程").font(Aurora.TypeStyle.heading); Spacer(); Text(model.usbConnected ? "USB 本地传输" : "插线即可接收 · 无需开课").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary) }
            HStack(spacing: Aurora.Space.small) {
                StatusNode(symbol: "iphone", title: "iPhone", detail: model.usbConnected ? "已连接" : "连接与解锁", color: Aurora.Colors.phone, ready: model.usbConnected) { model.connect() }
                link(ready: model.usbConnected)
                StatusNode(symbol: "desktopcomputer", title: "Mac", detail: "原图本地保存", color: Aurora.Colors.blue, ready: true) { model.showArchive() }
                link(ready: model.deliveryTarget == "native" ? model.chatMatchesClass : model.browserConnected)
                StatusNode(symbol: model.deliveryTarget == "native" ? "macwindow" : "puzzlepiece.extension.fill", title: model.deliveryTarget == "native" ? "AI App" : "浏览器扩展", detail: model.deliveryTarget == "native" ? model.chatMatchesClass ? "窗口已绑定" : "绑定当前窗口" : model.browserConnected ? "桥接已连接" : "安装或重新连接", color: Aurora.Colors.bridge, ready: model.deliveryTarget == "native" ? model.chatMatchesClass : model.browserConnected, action: configure)
                link(ready: model.chatMatchesClass)
                StatusNode(symbol: "bubble.left.and.bubble.right.fill", title: "AI 聊天", detail: hasFailure ? "发送待核对" : model.chatMatchesClass ? model.autoSend ? "自动发送" : "已绑定 · 暂停" : "选择并绑定目标", color: hasFailure ? Aurora.Colors.error : Aurora.Colors.target, ready: model.chatMatchesClass && model.browserPageStatus.isEmpty, action: configure)
            }.overlay {
                if let id = travellingID, let photo = model.records.first(where: { $0.id == id }), let url = model.imageURL(photo) {
                    GeometryReader { geometry in
                        let linkWidth = min(Aurora.Space.node, geometry.size.width / Aurora.Space.linkDivisor)
                        let nodeWidth = (geometry.size.width - linkWidth * Aurora.Space.links - Aurora.Space.small * Aurora.Space.pipelineGaps) / Aurora.Space.nodes
                        MacThumbnail(url: url).frame(width: Aurora.Space.travellingThumb, height: Aurora.Space.travellingThumb).clipped().clipShape(RoundedRectangle(cornerRadius: Aurora.Space.small))
                            .overlay(RoundedRectangle(cornerRadius: Aurora.Space.small).stroke(transferState == .sent ? Aurora.Colors.success : transferState == .uncertain ? Aurora.Colors.error : Aurora.Colors.blue, lineWidth: Aurora.Space.line))
                            .scaleEffect(arrival ? Aurora.Motion.arrivalScale : 1)
                            .position(x: nodeWidth / 2 + CGFloat(nodeIndex) * (nodeWidth + linkWidth + Aurora.Space.small * 2), y: Aurora.Space.travellingY)
                            .animation(reduceMotion ? nil : Aurora.Motion.state, value: nodeIndex)
                            .animation(reduceMotion ? nil : Aurora.Motion.state, value: arrival)
                    }.allowsHitTesting(false)
                }
            }
        }.padding(Aurora.Space.card).frame(height: Aurora.Space.pipeline).glassCard()
            .onChange(of: model.lastReceivedID) { _, id in
                animationTask?.cancel(); travellingID = id; nodeIndex = 0
                guard !reduceMotion else { return }; withAnimation(Aurora.Motion.state) { flash = true }; updateTravel()
            }
            .onChange(of: stateSignature) { _, _ in updateTravel() }
            .onDisappear { animationTask?.cancel() }
    }
    private func updateTravel() {
        guard !reduceMotion, travellingID != nil else { return }
        // Positions follow durable delivery events; no simulated "sent" state.
        let next = transferState == .sent ? 3 : [.preparing, .submitting, .failed, .uncertain].contains(transferState) ? 2 : 1
        animationTask?.cancel()
        animationTask = Task {
            do { try await Task.sleep(for: .seconds(Aurora.Motion.flash)) } catch { return }
            withAnimation(Aurora.Motion.state) { nodeIndex = next; flash = false; arrival = next == 3 }
            if next == 3 {
                do { try await Task.sleep(for: .seconds(Aurora.Motion.flash)) } catch { return }
                withAnimation(Aurora.Motion.state) { arrival = false; travellingID = nil }
            }
        }
    }

    private func link(ready: Bool) -> some View {
        Capsule().fill(ready ? Aurora.Colors.bridge.opacity(flash ? 1 : Aurora.Alpha.line) : Aurora.Colors.queued.opacity(Aurora.Alpha.dim)).frame(height: Aurora.Space.line).frame(maxWidth: Aurora.Space.node)
    }
}
struct StatTile: View {
    var value: Int, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.small) {
            Label("今日已发送", systemImage: "checkmark.circle.fill").foregroundStyle(Aurora.Colors.success).font(Aurora.TypeStyle.caption)
            Text("\(value)").font(Aurora.TypeStyle.number).contentTransition(.numericText())
            Text(detail).font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: Aurora.Space.tileHeight - Aurora.Space.card * 2).padding(Aurora.Space.card).glassCard().animation(Aurora.Motion.state, value: value)
    }
}
struct PhotoRow: View {
    @ObservedObject var model: WorkspaceModel
    var photo: PhotoRecord
    var open: () -> Void
    @State private var hover = false
    private var state: DeliveryState? { model.stageOf(photo) }
    private var color: Color { state == .sent ? Aurora.Colors.success : [.failed, .uncertain].contains(state) ? Aurora.Colors.error : Aurora.Colors.queued }
    var body: some View {
        HStack(spacing: Aurora.Space.inset) {
            Button(action: open) {
                if let url = model.imageURL(photo) { MacThumbnail(url: url).frame(width: Aurora.Space.thumb, height: Aurora.Space.thumb).clipped().clipShape(RoundedRectangle(cornerRadius: Aurora.Space.thumbRadius)) }
                else { Image(systemName: "photo").frame(width: Aurora.Space.thumb, height: Aurora.Space.thumb).background(Aurora.Colors.blue.opacity(Aurora.Alpha.icon), in: RoundedRectangle(cornerRadius: Aurora.Space.thumbRadius)) }
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: Aurora.Space.tiny) {
                Text(photo.receivedAt.formatted(date: .omitted, time: .shortened)).font(Aurora.TypeStyle.caption.monospacedDigit())
                Text(model.catalog.section(for: photo.sessionID)?.name ?? "收件箱").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary)
            }
            Spacer()
            if [.preparing, .submitting].contains(state) { ProgressView().controlSize(.small); Text("发送中").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.blue) }
            else { Label(state == .sent ? "已发送" : state == .failed ? "失败" : state == .uncertain ? "待核对" : "待发送", systemImage: state == .sent ? "checkmark.circle.fill" : [.failed, .uncertain].contains(state) ? "exclamationmark.circle.fill" : "clock").font(Aurora.TypeStyle.caption).foregroundStyle(color) }
            if state != .sent { Button(state == .uncertain ? "核对" : state == .failed ? "重发" : "发送") { if state == .uncertain { model.selected = photo.id; open() } else { model.sendSinglePhotoToAI(photo) } }.buttonStyle(.borderless).font(Aurora.TypeStyle.caption) }
        }.padding(.horizontal, Aurora.Space.small).frame(height: Aurora.Space.row)
            .background(Aurora.Colors.white.opacity(hover ? Aurora.Alpha.hover : 0), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius)).onHover { hover = $0 }.animation(Aurora.Motion.hover, value: hover)
    }
}
struct SectionRow: View {
    @ObservedObject var model: WorkspaceModel
    var section: CourseSection
    var color: Color
    var edit: () -> Void
    var body: some View {
        HStack(spacing: Aurora.Space.inset) {
            Capsule().fill(color).frame(width: Aurora.Space.bar)
            VStack(alignment: .leading, spacing: Aurora.Space.tiny) {
                Text(section.name).font(Aurora.TypeStyle.heading)
                Text(model.catalog.courses.first { $0.id == section.courseID }?.name ?? "").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                Text(section.schedule.map { String(format: "%02d:%02d – %02d:%02d", $0.startMinute / 60, $0.startMinute % 60, $0.endMinute / 60, $0.endMinute % 60) } ?? "未设置课表 · 手动选择").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary)
                if let schedule = section.schedule, schedule.contains(Date()) {
                    TimelineView(.periodic(from: .now, by: 60)) { clock in
                        let now = Calendar.current.dateComponents([.hour, .minute], from: clock.date)
                        let minute = (now.hour ?? 0) * 60 + (now.minute ?? 0)
                        VStack(alignment: .leading, spacing: Aurora.Space.tiny) {
                            Text("进行中 · 还剩 \(max(0, schedule.endMinute - minute)) 分钟").font(Aurora.TypeStyle.micro).foregroundStyle(color)
                            ProgressView(value: Double(max(0, min(minute - schedule.startMinute, schedule.endMinute - schedule.startMinute))), total: Double(schedule.endMinute - schedule.startMinute)).tint(color)
                        }
                    }
                }
            }
            Spacer()
            if model.targetSection?.id == section.id { Text("当前目标").font(Aurora.TypeStyle.micro).foregroundStyle(color) }
            Menu { Button("设为发送目标") { model.chooseSection(section.id) }; Button("编辑 Section 与聊天") { edit() } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.padding(Aurora.Space.inset).background(color.opacity(model.targetSection?.id == section.id ? Aurora.Alpha.icon : Aurora.Alpha.faint), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius))
            .contentShape(Rectangle()).onTapGesture { model.chooseSection(section.id) }
    }
}
struct EmptyPhotos: View {
    var inbox = false
    var body: some View {
        VStack(spacing: Aurora.Space.gap) {
            Image(systemName: inbox ? "tray" : "camera.viewfinder").font(Aurora.TypeStyle.number).foregroundStyle(Aurora.Colors.target)
            Text(inbox ? "收件箱已清空" : "还没有照片，用手机拍一张试试").font(Aurora.TypeStyle.body)
            Text(inbox ? "未分配的照片会保存在这里，随时归入 Section。" : "无需开始课堂；原图会先保存在 Mac。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
