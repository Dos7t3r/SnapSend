import SwiftUI
import AppKit
import SnapSendCore

struct DeliverySettingsSheet: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: String

    init(model: WorkspaceModel, initialTab: String = "prompts") {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Selection Bar
                HStack(spacing: 6) {
                    TabButton(title: "课堂提示词", icon: "sparkles", tag: "prompts", current: $selectedTab)
                    TabButton(title: "AI 投递", icon: "paperplane.fill", tag: "ai", current: $selectedTab)
                    TabButton(title: "照片与存储", icon: "internaldrive.fill", tag: "storage", current: $selectedTab)
                    TabButton(title: "连接与故障处理", icon: "cable.connector", tag: "usb", current: $selectedTab)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case "prompts":
                            promptsSettingsView
                        case "ai":
                            aiSettingsView
                        case "storage":
                            storageSettingsView
                        case "usb":
                            usbSettingsView
                        default:
                            EmptyView()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Footer Bar
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.usbConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("SnapSend v\(SnapSendVersion) · 照片先保存在本地，再投递到 AI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .frame(width: 720, height: 640)
            .navigationTitle("设置")
        }
    }

    // MARK: - 1. Prompts & Automation View

    @ViewBuilder
    private var promptsSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Automation Toggle
            VStack(alignment: .leading, spacing: 8) {
                Toggle("点击开始上课时，自动连接 AI 并在会话中发送开课提示词", isOn: $model.autoSendPromptOnStartLesson)
                    .font(.headline)
                Text("开始课堂后准备提示词；在 Chrome 绑定本节课聊天后自动发送。有草稿或 AI 正在回答时会等待。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Class Start Prompt
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("开课提示词 (用于告诉 AI 按图记录笔记与理解)", systemImage: "text.bubble.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("恢复默认") {
                            model.resetStartPromptToDefault()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    TextEditor(text: $model.classStartPrompt)
                        .font(.callout)
                        .frame(height: 80)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 10) {
                        Button("复制此提示词", systemImage: "doc.on.doc") {
                            model.copyClassPrompt()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("立即向当前 AI 聊天发送", systemImage: "paperplane.fill") {
                            model.sendClassStartPromptNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SnapTheme.blue)
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }

            // Summary Prompt
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("下课总结提示词 (下课时触发生成知识体系与习题)", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("恢复默认") {
                            model.resetSummaryPromptToDefault()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    TextEditor(text: $model.classSummaryPrompt)
                        .font(.callout)
                        .frame(height: 70)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 10) {
                        Button("复制总结提示词", systemImage: "doc.on.doc") {
                            model.copySummaryPrompt()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("立即向当前 AI 聊天发送总结", systemImage: "paperplane.fill") {
                            model.sendClassSummaryPromptNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - 2. AI Delivery Channels

    @ViewBuilder
    private var aiSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("投递通道选择") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("当前通道", selection: $model.deliveryTarget) {
                        Text("Chrome 扩展 · 推荐").tag("chrome")
                        Text("macOS 原生 ChatGPT App (实验性)").tag("native")
                    }
                    .pickerStyle(.radioGroup)

                    Text("Chrome 扩展支持后台静默投递，无需前台聚焦；原生客户端需要授予辅助功能权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            if model.deliveryTarget == "chrome" {
                GroupBox("Chrome 扩展安装与原生桥接") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第一步 · 安装本地桥接")
                                    .font(.subheadline.weight(.semibold))
                                Text("安装一次，让 Chrome 扩展能够连接这台 Mac。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("安装桥接") {
                                model.installChromeHost()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Divider()

                        HStack {
                            Button("打开 Chrome 扩展管理页", systemImage: "safari") {
                                model.openChromeExtensions()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("复制扩展目录路径", systemImage: "folder") {
                                model.copyExtensionPath()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                }
            } else {
                GroupBox("原生 ChatGPT App (辅助功能 AX)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("需要允许 SnapSend 控制电脑以定位 ChatGPT 窗口并点击上传。")
                            .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Button("测试并请求辅助功能权限", systemImage: "lock.shield") {
                                model.testNativeAccessibility()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - 3. Local Storage & Library

    @ViewBuilder
    private var storageSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            let stats = model.calculateStorageStats()

            GroupBox("本地存储容量与概览") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地归档照片总数")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(stats.count) 张")
                                .font(.title2.weight(.bold))
                        }

                        Divider().frame(height: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前磁盘占用")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(stats.sizeFormatted)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.blue)
                        }

                        Divider().frame(height: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("存储位置")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("~/Library/Application Support/SnapSend")
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("在访达中定位照片库", systemImage: "folder.fill") {
                            model.showArchive()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("一键清理临时投递缓存", systemImage: "trash") {
                            model.cleanCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }

            GroupBox("队列与完整性维护") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("重置待核对队列可清除所有卡在准备或异常状态的照片，允许重新发起投递。")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("重置待核对队列", systemImage: "arrow.counterclockwise") {
                            model.resetQueue()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - 4. USB & Diagnostics View

    @ViewBuilder
    private var usbSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("USB 连接与端口配置") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("拔插数据线自动重连 (Zero-Click Auto Reconnect)", isOn: $model.autoReconnect)
                        .font(.headline)
                    Text("开启后，iPhone 拔线或断开后将自动感应并在再次插入时完成连接与认证。")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack {
                        Text("本地 USB 代理端口：")
                        TextField("端口", text: $model.port)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(8)
            }

            GroupBox("USB 重连与故障排除") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重启 USB 桥接")
                                .font(.subheadline.weight(.semibold))
                            Text("断线后会逐步降低重试频率。此操作只重启 SnapSend 的桥接；端口被其他程序占用时，请更换上方端口。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("立即重连", systemImage: "cross.vial.fill") {
                            model.selfHealUSB()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("忘记已配对手机")
                                .font(.subheadline.weight(.semibold))
                            Text("清除 Mac 钥匙串中已记住的设备凭据，下一次插线需重新输入 6 位验证码。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("忘记配对设备", role: .destructive) {
                            model.forgetPairings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Subcomponents

private struct TabButton: View {
    let title: String
    let icon: String
    let tag: String
    @Binding var current: String

    var isSelected: Bool { current == tag }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                current = tag
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
