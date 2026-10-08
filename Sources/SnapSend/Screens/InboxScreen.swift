import SwiftUI
import SnapSendCore

struct InboxScreen: View {
    @ObservedObject var model: WorkspaceModel
    var openPhoto: (PhotoRecord) -> Void
    @State private var selected: Set<UUID> = []
    @State private var target: UUID?
    @State private var sendAfter = true
    @State private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            Text("收件箱").font(Aurora.TypeStyle.title).lineLimit(1)
            Text("没有发送或尚未分配的照片。先选照片，再归入一个 Section。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            HStack {
                Button(selected.count == model.pendingPhotos.count ? "取消全选" : "全选") { selected = selected.count == model.pendingPhotos.count ? [] : Set(model.pendingPhotos.map(\.id)) }.auroraButton()
                Picker("归入", selection: $target) { Text("选择 Section").tag(UUID?.none); ForEach(model.catalog.sections ?? []) { section in Text("\(model.catalog.courses.first { $0.id == section.courseID }?.name ?? "") · \(section.name)").tag(Optional(section.id)) } }.frame(maxWidth: 240)
                Menu { Button("导出选中原图") { model.selectedPhotoIDs = selected; model.batchExportSelected() }; Button("删除 Mac 原图", role: .destructive) { deleting = true } } label: { Text("更多").menuHitArea() }.menuStyle(.borderlessButton).fixedSize().disabled(selected.isEmpty)
                Toggle("同时发送", isOn: $sendAfter).toggleStyle(SpringToggle()).frame(maxWidth: 115).font(Aurora.TypeStyle.caption)
                Button("处理 \(selected.count) 张") { if let target { model.assignPhotos(selected, to: target, send: sendAfter); selected.removeAll() } }.auroraButton(primary: true).disabled(selected.isEmpty || target == nil)
            }.padding(.trailing, Aurora.Space.page)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Aurora.Space.small) {
                    if model.pendingPhotos.isEmpty { EmptyPhotos(inbox: true) }
                    ForEach(model.pendingPhotos.reversed()) { photo in
                        HStack {
                            Button { if selected.contains(photo.id) { selected.remove(photo.id) } else { selected.insert(photo.id) } } label: { Image(systemName: selected.contains(photo.id) ? "checkmark.circle.fill" : "circle").frame(width: 28, height: 44) }.buttonStyle(PressableStyle()).foregroundStyle(Aurora.Colors.target)
                            PhotoRow(model: model, photo: photo) { openPhoto(photo) }
                        }
                    }
                }.padding(Aurora.Space.card).glassCard().cardEntrance(0).padding(.trailing, Aurora.Space.page).padding(.bottom, Aurora.Space.page).animatedRows(model.pendingPhotos.map(\.id))
            }.scrollIndicators(.automatic).frame(maxWidth: .infinity, maxHeight: .infinity)

        }.confirmationDialog("删除所选 Mac 原图？", isPresented: $deleting) {
            Button("删除原图", role: .destructive) { model.selectedPhotoIDs = selected; model.batchDeleteSelected(); selected.removeAll() }
        } message: { Text("手机上的照片仍会保留。") }
    }
}
