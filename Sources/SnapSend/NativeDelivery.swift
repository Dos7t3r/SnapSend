import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum NativeDelivery {
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?; AXUIElementCopyAttributeValue(element, key as CFString, &result); return result
    }
    static func elements(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 24, result.count < 2500 else { return }
            result.append(e)
            for child in attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
        }
        walk(root, 0); return result
    }
    static func label(_ e: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
            .compactMap { attribute(e, $0) as? String }.joined(separator: " ")
    }
    static func app(_ bundle: String) throws -> NSRunningApplication {
        guard AXIsProcessTrusted() else { throw Failure("请先在系统设置 → 隐私与安全性 → 辅助功能中允许 SnapSend。") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            throw Failure("请先打开所选 ChatGPT App，并进入这节课专用的聊天。")
        }; return app
    }
    static func title(_ app: NSRunningApplication) throws -> String {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first,
              let title = attribute(window, kAXTitleAttribute) as? String, !title.isEmpty else {
            throw Failure("无法识别聊天窗口。请使用 Chrome 扩展，或打开带标题的 ChatGPT 聊天。")
        }
        guard !["chatgpt", "chatgpt classic", "new chat", "新聊天"].contains(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("窗口只有通用标题，无法区分聊天。请使用 Chrome 扩展绑定准确的聊天地址。")
        }
        return title
    }
    static func send(url: URL, bundle: String, windowTitle: String, submit: Bool,
                     beforeSubmit: () throws -> Void) async throws {
        let app = try app(bundle)
        guard try title(app) == windowTitle else { throw Failure("聊天窗口已变化，请回到绑定的聊天后重新绑定。") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func editor() -> AXUIElement? {
            elements(root).first { attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole }
        }
        guard let input = editor(), (attribute(input, kAXValueAttribute) as? String ?? "").isEmpty else {
            throw Failure("输入框有草稿或无法识别。请清空草稿，再重试；SnapSend 不会覆盖你的文字。")
        }
        let initial = elements(root)
        guard !initial.contains(where: { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
            label($0).range(of: "remove|移除|删除附件|stop generating|停止生成", options: .regularExpression) != nil }) else {
            throw Failure("ChatGPT 有附件草稿或正在回答，请先处理后重试。")
        }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents(); board.writeObjects([url as NSURL])
        let ownChange = board.changeCount
        defer {
            if board.changeCount == ownChange {
                board.clearContents()
                let items = saved.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
                board.writeObjects(items)
            }
        }
        app.activate()
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(350))
        // Send only to the editor we just focused; abort if the user changes foreground app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { throw Failure("焦点已变化，请重试。") }
        down.flags = .maskCommand; up.flags = .maskCommand; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  try title(app) == windowTitle else { throw Failure("上传期间切换了窗口。图片可能已附加，请到 ChatGPT 核对。") }
            let all = elements(root)
            let attached = all.contains { label($0).contains(url.lastPathComponent) } &&
                all.contains { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                    label($0).lowercased().range(of: "remove|移除|删除附件", options: .regularExpression) != nil }
            let button = all.first { e in
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(e, $0) as? String }
                    .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                return attribute(e, kAXRoleAttribute) as? String == kAXButtonRole &&
                    labels.contains(where: { ["send", "send message", "发送", "发送消息"].contains($0) }) &&
                    (attribute(e, kAXEnabledAttribute) as? Bool == true)
            }
            if attached, let button {
                if !submit { return }
                guard (attribute(input, kAXValueAttribute) as? String ?? "").isEmpty else {
                    throw Failure("上传期间输入框出现草稿，请核对附件后重试。")
                }
                try beforeSubmit()
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw Failure("发送按钮未响应，请核对聊天。") }
                return // Native AX cannot prove server acceptance; caller records an uncertain result.
            }
        }
        throw Failure("未能确认图片附件与可用发送按钮。请核对 ChatGPT 草稿；也可以使用 Chrome 扩展。")
    }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
