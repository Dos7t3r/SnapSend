import SwiftUI
import SnapSendCore

struct SettingsScreen: View {
    @ObservedObject var model: WorkspaceModel
    @State private var nativeExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            Text("设置与连接").font(Aurora.TypeStyle.title).lineLimit(1)
            Text("每条连接独立检查。即使 AI 暂时不能发送，USB 收到的原图仍会保存。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Aurora.Space.gap) {
                    group("iPhone / iPad · USB", symbol: "cable.connector", color: Aurora.Colors.phone, order: 0) {
                        Picker("USB 来源", selection: $model.usbMode) { Text("iPhone 拍照").tag("phone"); Text("iPad 截图分享").tag("pad") }.pickerStyle(.segmented)
                            .onChange(of: model.usbMode) { _, _ in model.disconnect(userInitiated: true, allowAutoReconnect: false) }
                        HStack {
                            Picker("USB 设备", selection: $model.usbDeviceID) {
                                Text("未选择设备").tag("")
                                ForEach(model.usbDevices, id: \.self) { id in Text("USB 设备 · " + id.suffix(8)).tag(id) }
                            }.onChange(of: model.usbDeviceID) { _, _ in model.disconnect(userInitiated: true, allowAutoReconnect: false) }
                            Button(model.findingUSB ? "查找中…" : "查找设备") { model.findUSBDevices() }.buttonStyle(AuroraInlineButton()).disabled(model.findingUSB)
                        }
                        if model.usbMode == "pad" {
                            Text("iPad 截图后点分享 → SnapSend；分享面板保持打开，再点击重新连接。首版仅保存到 Mac，可在 Mac 手动选图发送。多台设备插线时先拔掉 iPhone。").font(Aurora.TypeStyle.caption)
                        }
                        Text(model.connectionStatus).font(Aurora.TypeStyle.body)
                        Text("1. 插上数据线 → 2. 解锁并打开手机 SnapSend → 3. 首次连接输入手机显示的 6 位码。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                        if model.pairingRequired { HStack { TextField("6 位验证码", text: $model.pairingCode).textFieldStyle(.roundedBorder); Button("验证") { model.submitPairing() }.buttonStyle(AuroraInlineButton()) } }
                        HStack { Button("重新连接") { model.connect() }.buttonStyle(AuroraInlineButton()); Toggle("断线后自动重连", isOn: $model.autoReconnect).font(Aurora.TypeStyle.caption) }
                    }
                    group("Chrome · 自动发送", symbol: "puzzlepiece.extension.fill", color: Aurora.Colors.bridge, order: 1) {
                        Text(model.browserConnected ? "本机桥接已连接" : "等待浏览器连接").font(Aurora.TypeStyle.body)
                        Text("1. 安装本机桥接 → 2. 在 Chrome 扩展页打开开发者模式，加载扩展目录 → 3. 刷新 ChatGPT 页面 → 4. 选择 Section，在聊天页面点击扩展绑定。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                        HStack { Button("安装本机桥接") { model.installChromeHost() }.buttonStyle(AuroraInlineButton()); Button("打开扩展目录") { model.openExtensionFolder() }.buttonStyle(AuroraInlineButton()); Button("Chrome 扩展页") { model.openChromeExtensions() }.buttonStyle(AuroraInlineButton()) }
                        Text(model.browserPageStatus.isEmpty ? model.deliveryReport : model.browserPageStatus).font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                        Button("显示绑定聊天，处理等待状态") { model.requestBrowserFocus() }.buttonStyle(AuroraInlineButton()).disabled(!model.chatMatchesClass)
                    }
                    group("课堂提示词", symbol: "sparkles", color: Aurora.Colors.target, order: 2) {
                        TextEditor(text: $model.classStartPrompt).font(Aurora.TypeStyle.body).frame(minHeight: Aurora.Space.pipeline).scrollContentBackground(.hidden).background(Aurora.Colors.white.opacity(Aurora.Alpha.faint), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius))
                        HStack { Button("发送课堂提示词") { model.sendClassStartPromptNow() }.buttonStyle(AuroraInlineButton()).disabled(!model.chatMatchesClass); Button("复制") { model.copyClassPrompt() }.buttonStyle(AuroraInlineButton()) }
                        Text("下课复习").font(Aurora.TypeStyle.heading).lineLimit(1)
                        TextEditor(text: $model.classSummaryPrompt).font(Aurora.TypeStyle.body).frame(minHeight: Aurora.Space.row * 2).scrollContentBackground(.hidden).background(Aurora.Colors.white.opacity(Aurora.Alpha.faint), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius))
                        HStack { Button("发送下课总结") { model.sendClassSummaryPromptNow() }.buttonStyle(AuroraInlineButton()).disabled(!model.chatMatchesClass); Button("复制总结") { model.copySummaryPrompt() }.buttonStyle(AuroraInlineButton()) }
                    }
                    group("原生 AI App · 实验投递", symbol: "macwindow", color: Aurora.Colors.target, order: 3) {
                        DisclosureGroup("原生窗口投递与权限检查", isExpanded: $nativeExpanded) {
                            VStack(alignment: .leading, spacing: Aurora.Space.gap) {
                                Text("浏览器是默认路径。原生投递会短暂激活 AI 窗口并使用剪贴板，未确认发送时会暂停，请人工核对。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                                StringSegments(options: [("chrome", "Chrome 网页"), ("native", "原生 AI App")], value: Binding(get: { model.deliveryTarget }, set: { model.selectDeliveryTarget($0) }))
                                    .disabled(model.nativeBusy || model.deliveries.contains { [.preparing, .submitting].contains($0.state) })
                                if model.deliveryTarget == "native" {
                                    Text("1. 打开 AI App 的专用聊天 → 2. 检查辅助功能权限 → 3. 绑定当前窗口 → 4. 返回概览开启发送。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                                    HStack { Button("检查权限与窗口") { model.testNativeAccessibility() }.buttonStyle(AuroraInlineButton()); Button("选择 AI App") { model.chooseNativeApplication() }.buttonStyle(AuroraInlineButton()) }
                                    Text(model.axReport).font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary).lineLimit(6)
                                    HStack { Button("打开辅助功能设置") { model.openAccessibilitySettings() }.buttonStyle(AuroraInlineButton()); Button("绑定当前 AI 窗口") { model.bindNative() }.buttonStyle(AuroraInlineButton()) }
                                    Button("测试附图（不会点击发送）") { model.attachmentTest() }.buttonStyle(AuroraInlineButton()).disabled(model.current == nil || !model.chatMatchesClass || model.nativeBusy)
                                    Text("测试附图前先点开一张照片；确认聊天正确后再绑定。发送结果需核对的照片可在大图窗口处理。").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.tertiary)
                                }
                            }.padding(.top, Aurora.Space.gap)
                        }
                    }
                    group("本地照片与高级选项", symbol: "internaldrive", color: Aurora.Colors.blue, order: 4) {
                        Text("原图只保存在你的 Mac 和 iPhone。导出、移动、回收站在课程页；未分配照片在收件箱。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                        HStack { Button("打开归档目录") { model.showArchive() }.buttonStyle(AuroraInlineButton()); Button("导入照片") { model.importPhoto() }.buttonStyle(AuroraInlineButton()); Button("清理临时图片缓存") { model.cleanCache() }.buttonStyle(AuroraInlineButton()) }
                        Text("动态背景仅在窗口有焦点时运行；开启系统“减少动态效果”后保持静止。缩略图后台解码并限制缓存。").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.tertiary)
                    }
                }.padding(.trailing, Aurora.Space.page).padding(.bottom, Aurora.Space.page)
            }.scrollIndicators(.automatic)
        }
    }
    private func group<Content: View>(_ title: String, symbol: String, color: Color, order: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) { Label(title, systemImage: symbol).font(Aurora.TypeStyle.heading).lineLimit(1).foregroundStyle(color); content() }.padding(Aurora.Space.card).frame(maxWidth: .infinity, alignment: .leading).glassCard().cardEntrance(order)
    }
}
