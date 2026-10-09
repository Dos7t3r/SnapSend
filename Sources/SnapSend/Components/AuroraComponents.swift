import SwiftUI
import AppKit
import SnapSendCore

struct StatusNode: View {
    @Environment(\.auroraReduceMotion) private var reduceMotion
    var symbol: String, title: String, detail: String
    var color: Color, ready: Bool
    var actionTitle: String
    var needsAttention = false
    private var statusColor: Color { needsAttention ? Aurora.Colors.error : ready ? color : Aurora.Colors.queued }
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: Aurora.Space.small) {
                Image(systemName: symbol).font(Aurora.TypeStyle.heading).lineLimit(1).foregroundStyle(ready ? color : Aurora.Colors.tertiary)
                    .frame(width: Aurora.Space.node, height: Aurora.Space.node)
                    .background(statusColor.opacity(ready ? Aurora.Alpha.strong : Aurora.Alpha.faint), in: Circle())
                    .overlay(Circle().stroke(statusColor.opacity(ready ? Aurora.Alpha.ring : Aurora.Alpha.outline), lineWidth: Aurora.Space.line).allowsHitTesting(false))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .nonRepeating, value: reduceMotion ? false : ready)
                Text(title).font(Aurora.TypeStyle.body).foregroundStyle(Aurora.Colors.primary)
                Text(detail).font(Aurora.TypeStyle.micro).foregroundStyle(ready ? color : Aurora.Colors.secondary).lineLimit(1)
                if !ready { Text(actionTitle + " ›").font(Aurora.TypeStyle.micro).foregroundStyle(statusColor) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Aurora.Space.tiny)
        }.buttonStyle(PressableStyle(row: true)).help(detail)
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
    @Environment(\.auroraReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack { Text("照片的旅程").font(Aurora.TypeStyle.heading).lineLimit(1); Spacer(); Text(model.usbConnected ? "USB 本地传输" : "插线即可接收 · 无需开课").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary) }
            HStack(spacing: Aurora.Space.small) {
                StatusNode(symbol: model.usbMode == "pad" ? "ipad" : "iphone", title: model.usbMode == "pad" ? "iPad" : "iPhone", detail: model.usbConnected ? "已连接" : "连接与解锁", color: Aurora.Colors.phone, ready: model.usbConnected, actionTitle: model.usbMode == "pad" ? "连接 iPad" : "连接 iPhone") { model.connect(); configure() }
                link(ready: model.usbConnected)
                StatusNode(symbol: "desktopcomputer", title: "Mac", detail: "原图本地保存", color: Aurora.Colors.blue, ready: true, actionTitle: "查看归档") { model.showArchive() }
                link(ready: model.deliveryTarget == "native" ? model.chatMatchesClass : model.browserConnected)
                StatusNode(symbol: model.deliveryTarget == "native" ? "macwindow" : "puzzlepiece.extension.fill", title: model.deliveryTarget == "native" ? "AI App" : "浏览器扩展", detail: model.deliveryTarget == "native" ? model.chatMatchesClass ? "窗口已绑定" : "绑定当前窗口" : model.browserConnected ? "桥接已连接" : "安装或重新连接", color: Aurora.Colors.bridge, ready: model.deliveryTarget == "native" ? model.chatMatchesClass : model.browserConnected, actionTitle: model.deliveryTarget == "native" ? "绑定窗口" : "安装扩展", needsAttention: model.deliveryTarget == "chrome" && model.chatMatchesClass && !model.browserConnected, action: configure)
                link(ready: model.chatMatchesClass)
                StatusNode(symbol: "bubble.left.and.bubble.right.fill", title: "AI 聊天", detail: hasFailure ? "发送待核对" : !model.browserPageStatus.isEmpty ? model.browserPageStatus : model.chatMatchesClass ? model.autoSend ? "自动发送" : "已绑定 · 暂停" : "选择并绑定目标", color: hasFailure ? Aurora.Colors.error : Aurora.Colors.target, ready: model.chatMatchesClass && model.browserPageStatus.isEmpty, actionTitle: model.chatMatchesClass ? "回到聊天" : "选择聊天", needsAttention: hasFailure || (!model.browserPageStatus.isEmpty && !model.browserPageStatus.hasPrefix("等待：")), action: { if model.chatMatchesClass { model.requestBrowserFocus() } else { configure() } })
            }.overlay {
                if let id = travellingID, let photo = model.records.first(where: { $0.id == id }), let url = model.imageURL(photo) {
                    GeometryReader { geometry in
                        let linkWidth = min(Aurora.Space.node, geometry.size.width / Aurora.Space.linkDivisor)
                        let nodeWidth = (geometry.size.width - linkWidth * Aurora.Space.links - Aurora.Space.small * Aurora.Space.pipelineGaps) / Aurora.Space.nodes
                        MacThumbnail(url: url).frame(width: Aurora.Space.travellingThumb, height: Aurora.Space.travellingThumb).clipped().clipShape(RoundedRectangle(cornerRadius: Aurora.Space.small))
                            .overlay(RoundedRectangle(cornerRadius: Aurora.Space.small).stroke(transferState == .sent ? Aurora.Colors.success : transferState == .uncertain ? Aurora.Colors.error : Aurora.Colors.blue, lineWidth: Aurora.Space.line).allowsHitTesting(false))
                            .scaleEffect(arrival ? Aurora.Motion.arrivalScale : 1)
                            .position(x: nodeWidth / 2 + CGFloat(nodeIndex) * (nodeWidth + linkWidth + Aurora.Space.small * 2), y: Aurora.Space.travellingY)
                            .animation(reduceMotion ? nil : Aurora.Motion.state, value: nodeIndex)
                            .animation(reduceMotion ? nil : Aurora.Motion.state, value: arrival)
                    }.allowsHitTesting(false)
                }
            }
        }.padding(Aurora.Space.card).frame(maxWidth: .infinity).glassCard()
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

    private func link(ready: Bool) -> some View { PipelineLink(ready: ready).frame(height: 16).frame(maxWidth: Aurora.Space.node).allowsHitTesting(false) }

}
struct StatTile: View {
    @Environment(\.auroraReduceMotion) private var reduceMotion
    var value: Int, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.small) {
            Label("今日已发送", systemImage: "checkmark.circle.fill").foregroundStyle(Aurora.Colors.success).font(Aurora.TypeStyle.caption)
            Text("\(value)").font(Aurora.TypeStyle.number).contentTransition(reduceMotion ? .opacity : .numericText())
            Text(detail).font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary).contentTransition(reduceMotion ? .opacity : .numericText()).animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: detail)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: Aurora.Space.tileHeight - Aurora.Space.card * 2).padding(Aurora.Space.card).glassCard().animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: value)
    }
}
struct PhotoRow: View {
    @ObservedObject var model: WorkspaceModel
    var photo: PhotoRecord
    var open: () -> Void
    @Environment(\.auroraReduceMotion) private var reduceMotion
    @State private var deleting = false
    @State private var cancelling = false
    private var state: DeliveryState? { model.stageOf(photo) }
    private var color: Color { state == .sent ? Aurora.Colors.success : [.failed, .uncertain].contains(state) ? Aurora.Colors.error : Aurora.Colors.queued }
    var body: some View {
        HStack(spacing: 0) {
            ClickableRow(action: open) {
                HStack(spacing: Aurora.Space.inset) {
                    if let url = model.imageURL(photo) { MacThumbnail(url: url).frame(width: Aurora.Space.thumb, height: Aurora.Space.thumb).clipped().clipShape(RoundedRectangle(cornerRadius: Aurora.Space.thumbRadius)) }
                    else { Image(systemName: "photo").frame(width: Aurora.Space.thumb, height: Aurora.Space.thumb) }
                    VStack(alignment: .leading, spacing: Aurora.Space.tiny) {
                        Text(photo.receivedAt.formatted(date: .omitted, time: .shortened)).font(Aurora.TypeStyle.caption.monospacedDigit())
                        Text(model.catalog.section(for: photo.sessionID)?.name ?? "收件箱").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Label(state == .sent ? "已发送" : state == .failed ? "失败" : state == .uncertain ? "待核对" : [.preparing, .submitting].contains(state) ? "发送中" : state == .queued ? "待发送" : "仅保存", systemImage: state == .sent ? "checkmark.circle.fill" : [.failed, .uncertain].contains(state) ? "exclamationmark.circle.fill" : "clock")
                        .font(Aurora.TypeStyle.caption).foregroundStyle(color).lineLimit(1).contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }.padding(.horizontal, Aurora.Space.small).frame(height: Aurora.Space.row)
            }
            if state != .sent {
                Button(state == .uncertain ? "核对" : state == .failed ? "重发" : "发送") { if state == .uncertain { model.selected = photo.id; open() } else { model.sendSinglePhotoToAI(photo) } }
                    .buttonStyle(PressableStyle(inset: Aurora.Space.tiny)).font(Aurora.TypeStyle.caption)
            }
            Menu {
                if [.queued,.failed,.uncertain].contains(state) { Button("取消发送任务，保留原图") { cancelling = true } }
                Button("导出原图") { model.selectedPhotoIDs = [photo.id]; model.batchExportSelected() }
                Button("删除 Mac 原图",role:.destructive) { deleting = true }
            } label: { Image(systemName:"ellipsis").menuHitArea() }.menuStyle(.borderlessButton).fixedSize().handPointer()
        }.animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: state)
            .animatedRows(state)
            .confirmationDialog("删除 Mac 原图？",isPresented:$deleting) {
                Button("删除原图",role:.destructive) { model.selectedPhotoIDs = [photo.id]; model.batchDeleteSelected() }
            } message: { Text("删除 Mac 本地副本；不删除手机、iPad 来源 App 或 AI 聊天中的图片。") }
            .confirmationDialog("取消发送任务？",isPresented:$cancelling) {
                Button("取消任务，保留原图") { model.cancelDelivery(photo) }
            } message: { Text("不再发送这张图片；已到 AI 的消息不会撤回。聊天中若仍有附件，请先处理。") }
    }
}
struct SectionRow: View {
    @ObservedObject var model: WorkspaceModel
    var section: CourseSection
    var color: Color
    var edit: () -> Void
    @Environment(\.auroraReduceMotion) private var reduceMotion
    var body: some View {
        // Siblings, never a Menu inside a Button: the menu cannot change the target accidentally.
        HStack(spacing: 0) {
            ClickableRow { model.chooseSection(section.id) } content: {
                HStack(spacing: Aurora.Space.inset) {
                    Capsule().fill(color).frame(width: Aurora.Space.bar).allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: Aurora.Space.tiny) {
                        Text(section.name).font(Aurora.TypeStyle.heading).lineLimit(1)
                        Text(model.catalog.courses.first { $0.id == section.courseID }?.name ?? "").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).lineLimit(1)
                        Text(section.schedule.map { String(format: "%02d:%02d – %02d:%02d", $0.startMinute / 60, $0.startMinute % 60, $0.endMinute / 60, $0.endMinute % 60) } ?? "手动选择").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary).lineLimit(1)
                        if let schedule = section.schedule, schedule.contains(Date()) {
                            TimelineView(.periodic(from: .now, by: 60)) { clock in
                                let now = Calendar.current.dateComponents([.hour, .minute], from: clock.date)
                                Text("还剩 \(max(0, schedule.endMinute - (now.hour ?? 0) * 60 - (now.minute ?? 0))) 分钟").font(Aurora.TypeStyle.micro).foregroundStyle(color).contentTransition(reduceMotion ? .opacity : .numericText())
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if model.targetSection?.id == section.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(color).contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace)) }
                }.padding(Aurora.Space.inset)
            }
            Menu { Button("设为发送目标") { model.chooseSection(section.id) }; Button("编辑 Section 与聊天", action: edit) } label: { Image(systemName: "ellipsis").padding(.horizontal, Aurora.Space.small).menuHitArea() }
                .menuStyle(.borderlessButton).fixedSize().handPointer()
        }.background(color.opacity(model.targetSection?.id == section.id ? Aurora.Alpha.icon : Aurora.Alpha.faint), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius))
            .animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: model.targetSection?.id)
    }
}
struct PipelineLink: View {
    var ready: Bool
    @Environment(\.auroraReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var active
    @State private var grown = false
    @State private var position: CGFloat = 0
    @State private var appActive = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Path { path in path.move(to: CGPoint(x: 0, y: 8)); path.addLine(to: CGPoint(x: geometry.size.width, y: 8)) }
                    .stroke(Aurora.Colors.queued.opacity(grown ? 0 : 0.5), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Path { path in path.move(to: CGPoint(x: 0, y: 8)); path.addLine(to: CGPoint(x: geometry.size.width, y: 8)) }
                    .trim(from: 0, to: grown ? 1 : 0)
                    .stroke(Aurora.Colors.selected, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if grown && !reduceMotion && active == .key && appActive {
                    TimelineView(.periodic(from: .now, by: Aurora.Motion.frameInterval)) { clock in
                        Circle().fill(Aurora.Colors.bridge).frame(width: 4, height: 4).shadow(color: Aurora.Colors.bridge, radius: 3)
                            .modifier(FlowPosition(phase: position, width: geometry.size.width))
                            .onChange(of: clock.date) { _, date in
                                withAnimation(Aurora.Motion.flow) { position += 1 }
                            }
                    }
                }
            }.frame(height: 16)
        }.onAppear { appActive = NSApplication.shared.isActive; withAnimation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.grow) { grown = ready } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
            .onChange(of: ready) { _, value in withAnimation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.grow) { grown = value } }
    }
}
private struct FlowPosition: AnimatableModifier {
    nonisolated var phase: CGFloat
    nonisolated var width: CGFloat
    nonisolated var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func body(content: Content) -> some View { content.offset(x: (phase - floor(phase)) * max(0, width - 4)) }
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
