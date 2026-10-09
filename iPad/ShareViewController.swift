import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var finished = false
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SharePanel(model:model, finish:{ [weak self] in self?.finish() }))
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo:view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo:view.trailingAnchor), host.view.topAnchor.constraint(equalTo:view.topAnchor), host.view.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        host.didMove(toParent:self); preferredContentSize = CGSize(width:540,height:640)
        model.start(items:extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [])
    }
    private func finish() {
        guard !finished else { return }; finished = true; model.stop()
        extensionContext?.completeRequest(returningItems:nil)
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); model.stop() }
}

struct PadButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth:.infinity, minHeight:44)
            .padding(.horizontal,16).background(SnapTheme.gradient.opacity(enabled ? 1 : 0.35),in:RoundedRectangle(cornerRadius:16))
            .foregroundStyle(.white).contentShape(RoundedRectangle(cornerRadius:16))
            .scaleEffect(reduce ? 1 : configuration.isPressed ? 0.97 : 1)
            .animation(reduce ? SnapTheme.Motion.fade : SnapTheme.Motion.press,value:configuration.isPressed)
    }
}

struct SharePanel: View {
    @ObservedObject var model: ShareModel
    let finish: () -> Void
    @State private var confirmDelete = false
    var body: some View {
        ZStack {
            SnapBackdrop(paused:true)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack {
                        Image("SnapMark").resizable().scaledToFit().frame(width:44,height:44)
                        VStack(alignment:.leading) { Text("SnapSend").font(.title2.bold()); Text("截图留在本地").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("关闭",action:finish).frame(minWidth:60,minHeight:44).contentShape(Rectangle())
                    }
                    if let preview = model.preview {
                        Image(uiImage:preview).resizable().scaledToFit().frame(maxWidth:.infinity,maxHeight:200).clipShape(RoundedRectangle(cornerRadius:16)).allowsHitTesting(false)
                    } else {
                        Label(model.importing ? "正在准备图片" : "图片已保留在待传队列",systemImage:"photo.on.rectangle").frame(maxWidth:.infinity,minHeight:120).background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
                    }
                    VStack(alignment:.leading,spacing:12) {
                        Label(model.connected ? "USB 已连接" : "等待 USB 连接",systemImage:model.connected ? "checkmark.circle.fill" : "cable.connector").foregroundStyle(model.connected ? .green : .secondary)
                        Text(model.context.map { "目标：\($0.displayName)" } ?? "未指定课堂 · 保存到 Mac 收件箱").font(.headline).lineLimit(1)
                        Text(model.status).font(.subheadline)
                        if let code = model.pairingCode {
                            Text(code).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                            Text("在 Mac 的 SnapSend 中输入这 6 位码。60 秒内有效，之后会记住配对。").font(.caption)
                        }
                        if let error = model.error { Text(error).font(.subheadline).foregroundStyle(.orange) }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.thinMaterial,in:RoundedRectangle(cornerRadius:20))
                    Text("\(model.images.count) 张待传 · 已确认 \(model.completed) 张").font(.caption).contentTransition(.numericText())
                    Text("首个验证版仅保存到 Mac，不自动上传 AI。到 Mac 选中截图后，可用“只发送这一张”。").font(.caption).foregroundStyle(.secondary)
                    Button(model.transferring ? "正在等待 Mac 保存确认…" : "保存到 Mac") { model.beginTransfer() }.buttonStyle(PadButtonStyle()).disabled(!model.connected || model.importing || model.images.isEmpty || model.transferring)
                    if !model.connected {
                        Text("1. 用数据线连接并解锁 iPad。\n2. Mac 设置 → USB 来源 → iPad 截图分享。\n3. 保持此面板打开，在 Mac 点击重新连接。\n多台设备接线时，先拔掉 iPhone。").font(.caption).foregroundStyle(.secondary)
                        Button("重新等待连接") { model.retry() }.buttonStyle(PadButtonStyle()).disabled(model.importing)
                    }
                    if !model.images.isEmpty && !model.transferring && !model.importing {
                        Button("删除未传图片",role:.destructive) { confirmDelete = true }.frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
                    }
                    Text("取消或断线会保留未确认图片；下次从分享菜单打开时手动重试。Mac 确认后关闭面板，不等待 AI。").font(.caption2).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth:560).frame(maxWidth:.infinity)
            }.scrollIndicators(.automatic)
        }
        .animation(SnapTheme.Motion.fade,value:model.connected)
        .animation(SnapTheme.Motion.fade,value:model.completed)
        .onChange(of:model.transferring) { _, transferring in if !transferring && model.completed > 0 && model.images.isEmpty { finish() } }
        .alert("删除待传图片？",isPresented:$confirmDelete) {
            Button("取消",role:.cancel) {}
            Button("删除",role:.destructive) { model.deletePending() }
        } message:{ Text("只删除 SnapSend 的待传副本，不删除来源 App 的原图。") }
    }
}
