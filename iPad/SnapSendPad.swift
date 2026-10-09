import SwiftUI

@main
struct SnapSendPadApp: App {
    var body: some Scene { WindowGroup { PadWelcome() } }
}

struct PadWelcome: View {
    var body: some View {
        ZStack {
            SnapBackdrop(paused:true)
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Image("SnapMark").resizable().scaledToFit().frame(width:80,height:80).allowsHitTesting(false)
                    Text("截图，一键到 Mac").font(.largeTitle.bold())
                    Text("SnapSend for iPad · USB 分享验证版").font(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:20) {
                        step("1", "连接数据线", "iPad 插上 Mac，解锁并信任电脑。无需开启个人热点。")
                        step("2", "打开截图的分享菜单", "选择 SnapSend。找不到时在“更多”中启用，之后可以加入收藏。")
                        step("3", "选择 iPad USB 来源", "在 Mac 的 SnapSend 设置中选“iPad 截图分享”，保持分享面板打开，然后重新连接。首次在 Mac 输入分享面板的六位码。")
                        step("4", "保存到 Mac", "点保存，看到 Mac 确认后面板关闭。到 Mac 选图可手动发送 AI。")
                    }.padding(24).background(.thinMaterial,in:RoundedRectangle(cornerRadius:24))
                    Text("这个 App 不调用相机，也不扫描你的相册。传输只在分享面板打开时运行。未传完的图片保留在分享扩展，下次分享时可重试；主 App 不启动常驻 USB 服务。").font(.footnote).foregroundStyle(.secondary)
                    Text("首版接受最多 5 张 PNG / JPEG，每张不超过 20MB。正式一键发送 AI 将在真机 USB 验证后接入。").font(.footnote).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth:680).frame(maxWidth:.infinity)
            }.scrollIndicators(.automatic)
        }
    }
    private func step(_ n:String,_ title:String,_ description:String) -> some View {
        HStack(alignment:.top,spacing:16) {
            Text(n).font(.title3.bold()).foregroundStyle(.white).frame(width:36,height:36).background(SnapTheme.gradient,in:Circle())
            VStack(alignment:.leading,spacing:6) { Text(title).font(.headline); Text(description).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}
