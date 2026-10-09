import SwiftUI
import SnapSendCore

struct OverviewScreen: View {
    @ObservedObject var model: WorkspaceModel
    var configure: () -> Void
    var changeTarget: () -> Void
    var openPhoto: (PhotoRecord) -> Void
    private var problems: [String] {
        var result: [String] = []
        if model.deliveries.contains(where: { [.failed, .uncertain].contains($0.state) }) { result.append("有发送结果需要核对，打开照片确认后再发送") }
        if model.deliveryTarget == "chrome", !model.browserPageStatus.isEmpty { result.append(model.browserPageStatus) }
        if !model.usbConnected { result.append("连接 iPhone 数据线，解锁并打开 SnapSend") }
        if model.deliveryTarget == "chrome", !model.browserConnected { result.append("打开 Chrome 的 SnapSend 扩展，检查本机桥接") }
        if !model.chatMatchesClass { result.append("选择 Section，并绑定专用 ChatGPT 聊天") }
        if !model.autoSend { result.append("开启自动发送；照片仍会先保存在 Mac") }

        return result
    }
    private var sentToday: Int { let sent = Set(model.deliveries.filter { $0.state == .sent }.map(\.id)); return model.records.filter { Calendar.current.isDateInToday($0.receivedAt) && sent.contains($0.id) }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Aurora.Space.small) {
                    Text(problems.isEmpty ? "就绪" : "有 \(problems.count) 项需要处理").font(Aurora.TypeStyle.title).foregroundStyle(problems.isEmpty ? Aurora.Colors.success : Aurora.Colors.primary).contentTransition(.numericText())
                    Text((model.usbConnected ? "可以拍照 · 原图本地保存。" : "手机可离线拍照，插线后同步。") + (problems.first ?? "确认后自动发送给 AI")).font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).lineLimit(2)
                }
                Spacer()
                Text(Date().formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN")))).font(Aurora.TypeStyle.caption).padding(Aurora.Space.inset).background(Aurora.Colors.white.opacity(Aurora.Alpha.label), in: Capsule())
            }
            PipelineView(model: model, configure: configure)
            GeometryReader { geometry in
                let unit = (geometry.size.width - Aurora.Space.gap * 2) / Aurora.Space.columns
                HStack(alignment: .top, spacing: Aurora.Space.gap) {
                VStack(alignment: .leading, spacing: Aurora.Space.small) {
                    HStack { Label("发送目标", systemImage: "scope").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.target); Spacer(); Button("更换", action: changeTarget).buttonStyle(.borderless).font(Aurora.TypeStyle.caption) }
                    Text(model.targetSection.map { section in (model.catalog.courses.first { $0.id == section.courseID }?.name ?? "") + " · " + section.name } ?? "收件箱").font(Aurora.TypeStyle.heading).lineLimit(1)
                    Text(model.chatDisplayName).lineLimit(1).font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                    Text(model.targetSection?.schedule?.contains(Date()) == true ? "按课表自动选择" : model.targetSection == nil ? "照片暂存，稍后分配" : "手动选择 · 课表优先").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: Aurora.Space.tileHeight - Aurora.Space.card * 2).padding(Aurora.Space.card).glassCard().frame(width: unit * 2)
                StatTile(value: sentToday, detail: "排队 \(model.deliveries.filter { $0.state == .queued }.count) · 待核对 \(model.deliveries.filter { [.uncertain, .failed].contains($0.state) }.count)").frame(width: unit)
                VStack(alignment: .leading, spacing: Aurora.Space.small) {
                    Toggle("自动发送", isOn: Binding(get: { model.autoSend }, set: { $0 ? model.enableDelivery() : model.pauseDelivery() })).font(Aurora.TypeStyle.heading).toggleStyle(.switch).tint(Aurora.Colors.success)
                    Text(model.autoSend ? "等待照片，按顺序发送" : "照片会继续保存").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                    Button(model.browserPageStatus.isEmpty ? "查看绑定聊天" : "打开聊天处理") { model.requestBrowserFocus() }.buttonStyle(.borderless).font(Aurora.TypeStyle.micro).disabled(!model.chatMatchesClass)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: Aurora.Space.tileHeight - Aurora.Space.card * 2).padding(Aurora.Space.card).glassCard().frame(width: unit)
                }
            }.frame(height: Aurora.Space.tileHeight)
            GeometryReader { geometry in
            HStack(alignment: .top, spacing: Aurora.Space.gap) {
                VStack(alignment: .leading, spacing: Aurora.Space.small) {
                    HStack { Text("发送记录").font(Aurora.TypeStyle.heading); Spacer(); Text("\(model.records.count) 张").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary) }
                    if model.records.isEmpty { EmptyPhotos() }
                    else { ScrollView { LazyVStack(spacing: Aurora.Space.tiny) { ForEach(model.records.reversed()) { photo in PhotoRow(model: model, photo: photo) { openPhoto(photo) }.transition(.move(edge: .top).combined(with: .opacity)) } } } }
                }.padding(Aurora.Space.card).frame(width: (geometry.size.width - Aurora.Space.gap) * Aurora.Space.historyShare, height: geometry.size.height).glassCard()
                VStack(alignment: .leading, spacing: Aurora.Space.small) {
                    Text("今日 Section").font(Aurora.TypeStyle.heading)
                    ScrollView { LazyVStack(spacing: Aurora.Space.small) {
                        ForEach(todaySections) { section in SectionRow(model: model, section: section, color: Aurora.courseColor(model.catalog.courses.firstIndex { $0.id == section.courseID } ?? 0), edit: changeTarget) }
                        if todaySections.isEmpty { Text("还没有 Section\n在课程中添加，或先拍照到收件箱。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).padding(.vertical, Aurora.Space.gap) }
                    } }
                }.padding(Aurora.Space.card).frame(maxWidth: .infinity, maxHeight: .infinity).glassCard()
            }
            }.frame(maxHeight: .infinity)
        }
    }
    private var todaySections: [CourseSection] { (model.catalog.sections ?? []).filter { s in model.catalog.courses.contains { $0.id == s.courseID && $0.archived != true } && (s.schedule == nil || s.schedule?.weekday == Calendar.current.component(.weekday, from: Date())) }.sorted { ($0.schedule?.startMinute ?? 1440) < ($1.schedule?.startMinute ?? 1440) } }
}
