import SwiftUI
import SnapSendCore

struct OverviewScreen: View {
    @ObservedObject var model: WorkspaceModel
    var configure: () -> Void
    var changeTarget: () -> Void
    var openPhoto: (PhotoRecord) -> Void
    var showHistory: () -> Void
    @State private var expanded = false
    @State private var sectionEditor: CourseSection?
    @Environment(\.auroraReduceMotion) private var reduceMotion
    private var waitingForChat: Bool { model.browserPageStatus.hasPrefix("等待：") }
    private var problems: [String] {
        var result: [String] = []
        if model.deliveries.contains(where: { [.failed, .uncertain].contains($0.state) }) { result.append("有发送结果需要核对，打开照片确认后再发送") }
        if model.deliveryTarget == "chrome", model.chatMatchesClass, !model.browserPageStatus.isEmpty, !waitingForChat { result.append(model.browserPageStatus) }
        if model.deliveryTarget == "chrome", model.chatMatchesClass, !model.browserConnected { result.append("已绑定的浏览器连接中断，请打开扩展重新连接") }
        return result
    }
    private var headline: String {
        if !problems.isEmpty { return "需要处理" }
        if !model.usbConnected { return model.usbMode == "pad" ? "等待连接 iPad" : "等待连接 iPhone" }
        if !model.chatMatchesClass { return "可以拍照 · 等待绑定聊天" }
        if model.autoSend && waitingForChat { return "等待聊天就绪" }
        return model.autoSend ? "就绪" : "可以拍照 · 自动发送已暂停"
    }
    private var sentToday: Int { let sent = Set(model.deliveries.filter { $0.state == .sent }.map(\.id)); return model.records.filter { Calendar.current.isDateInToday($0.receivedAt) && sent.contains($0.id) }.count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Aurora.Space.gap) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Aurora.Space.small) {
                        Text(headline).font(Aurora.TypeStyle.title).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(!problems.isEmpty ? Aurora.Colors.error : model.autoSend && model.usbConnected && !waitingForChat ? Aurora.Colors.success : Aurora.Colors.primary)
                        Text(problems.first ?? (waitingForChat ? model.browserPageStatus : model.usbConnected ? "照片先保存在 Mac，绑定聊天后可自动发送。" : "手机可离线拍照。插线、解锁并打开 SnapSend 即可同步。"))
                            .font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button(action: showHistory) { Text(Date().formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN")))).font(Aurora.TypeStyle.caption).padding(Aurora.Space.inset).background(.white.opacity(Aurora.Alpha.label), in: Capsule()) }
                        .buttonStyle(PressableStyle(radius: 40)).help("查看按日期排列的全部发送记录")
                }.cardEntrance(0)
                PipelineView(model: model, configure: configure).cardEntrance(1)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Aurora.Space.gap) { targetCard.frame(minWidth: 340); StatTile(value: sentToday, detail: queueDetail).cardEntrance(3).frame(minWidth: 170); sendCard.frame(minWidth: 180) }
                    VStack(spacing: Aurora.Space.gap) { targetCard; HStack(alignment: .top, spacing: Aurora.Space.gap) { StatTile(value: sentToday, detail: queueDetail).cardEntrance(3); sendCard } }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Aurora.Space.gap) { historyCard.frame(minWidth: 340); sectionsCard.frame(minWidth: 340) }
                    VStack(spacing: Aurora.Space.gap) { historyCard; sectionsCard }
                }
            }.padding(.trailing, Aurora.Space.page).padding(.bottom, Aurora.Space.page)
        }.scrollIndicators(.automatic)
            .sheet(item: $sectionEditor) { section in SectionEditor(model: model, section: section) }
    }
    private var queueDetail: String { "排队 \(model.deliveries.filter { $0.state == .queued }.count) · 待核对 \(model.deliveries.filter { [.uncertain, .failed].contains($0.state) }.count)" }
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.small) {
            HStack { Label("发送目标", systemImage: "scope").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.target); Spacer(); Button("更换", action: changeTarget).buttonStyle(PressableStyle(inset: Aurora.Space.tiny)).font(Aurora.TypeStyle.caption) }
            Text(model.targetSection.map { section in (model.catalog.courses.first { $0.id == section.courseID }?.name ?? "") + " · " + section.name } ?? "收件箱").font(Aurora.TypeStyle.heading).lineLimit(1)
            Text(model.chatDisplayName).lineLimit(1).font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            Text(model.targetSection?.schedule?.contains(Date()) == true ? "按课表自动选择" : model.targetSection == nil ? "照片暂存，稍后分配" : "手动选择 · 课表优先").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.tertiary)
        }.padding(Aurora.Space.card).frame(maxWidth: .infinity, alignment: .leading).glassCard().cardEntrance(2)
    }
    private var sendCard: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.small) {
            Toggle("自动发送", isOn: Binding(get: { model.autoSend }, set: { $0 ? model.enableDelivery() : model.pauseDelivery() })).font(Aurora.TypeStyle.heading).toggleStyle(SpringToggle())
            if !model.autoSend && model.deliveries.contains(where: { $0.state == .queued && model.matchesTarget($0.lessonID) }) {
                Button("恢复队列与自动发送") { model.resumeDelivery() }.buttonStyle(AuroraInlineButton())
            }
            Text(model.autoSend ? "等待照片，按顺序发送" : "照片会继续保存").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            Button(model.browserPageStatus.isEmpty ? "查看绑定聊天" : "打开聊天处理") { model.requestBrowserFocus() }.buttonStyle(PressableStyle(inset: Aurora.Space.tiny)).font(Aurora.TypeStyle.micro).disabled(!model.chatMatchesClass)
        }.padding(Aurora.Space.card).frame(maxWidth: .infinity, alignment: .leading).glassCard().cardEntrance(4)
    }
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.small) {
            HStack { Text("发送记录").font(Aurora.TypeStyle.heading).lineLimit(1); Spacer(); Text("\(model.records.count) 张").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).contentTransition(reduceMotion ? .opacity : .numericText()).animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: model.records.count) }
            if model.records.isEmpty { EmptyPhotos().padding(.vertical, Aurora.Space.gap) }
            ForEach(Array(model.records.reversed().prefix(6))) { photo in PhotoRow(model: model, photo: photo) { openPhoto(photo) } }
            ClickableRow(action: showHistory) { Text("查看全部 →").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.blue).padding(Aurora.Space.small) }
        }.padding(Aurora.Space.card).frame(maxWidth: .infinity, alignment: .leading).glassCard().cardEntrance(5).animatedRows(model.records.map(\.id))
    }
    private var sectionsCard: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.small) {
            Text("今日 Section").font(Aurora.TypeStyle.heading).lineLimit(1)
            ForEach(Array(todaySections.prefix(expanded ? todaySections.count : 6))) { section in SectionRow(model: model, section: section, color: Aurora.courseColor(model.catalog.courses.firstIndex { $0.id == section.courseID } ?? 0)) { sectionEditor = section } }
            if todaySections.count > 6 {
                ClickableRow { withAnimation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state) { expanded.toggle() } } content: { Text(expanded ? "收起" : "更多 \(todaySections.count - 6) 个").font(Aurora.TypeStyle.caption).padding(Aurora.Space.small) }
            }
            if todaySections.isEmpty { Text("还没有 Section。在课程中添加，或先拍照到收件箱。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).padding(.vertical, Aurora.Space.gap) }
        }.padding(Aurora.Space.card).frame(maxWidth: .infinity, alignment: .leading).glassCard().cardEntrance(6).animatedRows(todaySections.map(\.id))
    }
    private var todaySections: [CourseSection] { (model.catalog.sections ?? []).filter { s in model.catalog.courses.contains { $0.id == s.courseID && $0.archived != true } && (s.schedule == nil || s.schedule?.weekday == Calendar.current.component(.weekday, from: Date())) }.sorted { ($0.schedule?.startMinute ?? 1440) < ($1.schedule?.startMinute ?? 1440) } }
}
struct HistoryScreen: View {
    @ObservedObject var model: WorkspaceModel
    var openPhoto: (PhotoRecord) -> Void
    var back: () -> Void
    @State private var filter = "全部"
    @State private var cancellingQueue = false
    @Namespace private var selection
    @Environment(\.auroraReduceMotion) private var reduceMotion
    private var photos: [PhotoRecord] { Array(model.records.reversed()).filter { filter == "全部" || (filter == "已发送" ? model.stageOf($0) == .sent : filter == "待发送" ? [.queued,.preparing,.submitting].contains(model.stageOf($0)) : [.failed, .uncertain].contains(model.stageOf($0))) } }
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack { Button("返回概览", systemImage: "arrow.left", action: back).auroraButton(); Text("发送任务与照片").font(Aurora.TypeStyle.title).lineLimit(1); Spacer() }.padding(.trailing, Aurora.Space.page)
            HStack {
                ForEach(["全部", "待发送", "已发送", "待处理"], id: \.self) { item in
                    Button { withAnimation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state) { filter = item } } label: {
                        Text(item).frame(maxWidth: .infinity, alignment: .leading).padding(Aurora.Space.small)
                            .background { if filter == item { RoundedRectangle(cornerRadius: Aurora.Space.rowRadius).fill(Aurora.Colors.selected).matchedGeometryEffect(id: "filter", in: selection).allowsHitTesting(false) } }
                    }.buttonStyle(PressableStyle(row: true))
                }
            }.padding(.trailing, Aurora.Space.page)
            HStack {
                Button("恢复当前队列与自动发送") { model.resumeDelivery() }.buttonStyle(AuroraInlineButton()).disabled(!model.chatMatchesClass || model.deliveries.contains { [.preparing,.submitting,.uncertain,.failed].contains($0.state) && model.matchesTarget($0.lessonID) })
                Button("取消当前课堂待发任务") { cancellingQueue = true }.buttonStyle(AuroraInlineButton()).disabled(!model.deliveries.contains { model.matchesTarget($0.lessonID) && [.queued,.failed,.uncertain].contains($0.state) })
                Button("暂停发送") { model.pauseDelivery() }.buttonStyle(AuroraInlineButton())
            }.padding(.trailing,Aurora.Space.page)
            Text("取消任务会保留原图；删除图片在每行的更多菜单。草稿发送或清空、AI 回答结束后会自动继续检查。待核对任务先确认结果，再恢复队列。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary).fixedSize(horizontal: false, vertical: true).padding(.trailing,Aurora.Space.page)
                LazyVStack(spacing: Aurora.Space.tiny) {
                    ForEach(photos) { photo in PhotoRow(model: model, photo: photo) { openPhoto(photo) } }
                    if photos.isEmpty { if filter == "全部" { EmptyPhotos() } else { Text("暂无\(filter)的记录").foregroundStyle(Aurora.Colors.secondary).frame(maxWidth: .infinity).padding(Aurora.Space.card) } }
                }.padding(Aurora.Space.card).glassCard().padding(.trailing, Aurora.Space.page).padding(.bottom, Aurora.Space.page).animatedRows(photos.map(\.id))
          }
        }.scrollIndicators(.automatic).frame(maxWidth: .infinity, maxHeight: .infinity).id(filter)
        .confirmationDialog("取消当前课堂的待发任务？",isPresented:$cancellingQueue) {
            Button("取消待发任务，保留照片") { model.cancelPendingDeliveries() }
        } message: { Text("已开始上传的任务不会被删除；AI 已收到的图片不会撤回。聊天中若仍有附件，请先处理。") }
    }
}
