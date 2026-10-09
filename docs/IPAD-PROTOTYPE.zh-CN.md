# iPad USB 分享原型

2026 年 10 月 9 日：新增独立 `iPad/SnapSendPad.xcodeproj`，包含 `SnapSendPad` 容器 App、`SnapSendShare` 系统分享扩展和 `ShareTests`。个人开发账号签名、iPad 安装成功；首次启动被 iOS 的开发者信任检查阻止，用户信任后确认主 App 可打开、分享菜单有 SnapSend，并反馈可以保存到 Mac。

这是归档验证版：不调用相机、不扫描相册、不自动发送 AI。Mac 收到后可手动选图发送。明确的一次性 AI 授权和三端流程优化属于下一轮；不能把这版描述为完整的一键 AI 投递。

## 使用

1. iPad 用数据线连接 Mac，解锁并信任电脑；截图后点分享 → SnapSend，第一次可在“更多”里找并加入收藏。
2. Mac 设置 → USB 来源 → iPad 截图分享。点“查找设备”；只插一台 USB 设备会自动选择，多台时明确选择设备（首版显示设备标识末八位）。不知道对应哪台时，先只插 iPad，再查找。不会通过 Wi-Fi 发现设备。
3. 分享面板保持打开，在 Mac 重新连接。首次把面板上的六位码填到 Mac；之后由扩展自身的 Keychain 记住配对。主 App 不和扩展共享队列，不依赖 App Groups。
4. 点“保存到 Mac”。按当前 Mac Section 归档，未指定目标进入收件箱。Mac 保存确认后关闭面板，不等待 AI。
5. 断线/关闭面板保留未确认图片，下次从分享菜单打开时可手动重试。点击保存会传当前显示数量的待传图片，包括以前保留的副本；不会宣称后台自动续传。可明确删除未传副本，不删除来源 App 原图。

## 资源与边界

- PNG/JPEG 原文件保留：不转全尺寸 UIImage/JPEG。Mac 按 ImageIO 类型保存正确后缀；移动课堂与导出保持格式，AI 上传仍使用 Mac 既有压缩图路径。
- 首版每次最多 5 张，每张最多 20MB；扩展私有待传目录总预算 100MB，达到预算会提示，未确认原图不被静默删掉。
- ImageIO 预览最长边 480px，仅保存一张预览。文件检查及 SHA-256 增量处理，传输一次只有一个 256KB 块等待完成；不拼整张图的 WireEncoder 缓冲。
- 静态背景、没有常驻相机或主 App USB 监听。分享面板取消/消失时取消 listener、connection、传输任务和超时任务。
- 首版 USB 接收端沿用 Mac 现有有界 WireDecoder，仍会缓存一张完整原图；此次未改成 Mac 落盘流式接收。
- Mac USB 设备发现是用户触发的一次有超时的 usbmux 请求；设备选择用于 iproxy 的明确 UDID，重连沿用已有退避。
- AI 许可固定 `sendToAI=false`，与 Mac 自动发送是否开启无关。长期未打开扩展时不会自行继续传输。

Share Extension 的生命周期由系统控制，成功后应结束请求；主 App 不能替扩展长期保活。参见 [Apple Share Extension 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)。

## 实际验证

| 项目 | 结果 |
|---|---|
| iPad Release 容器 + 扩展 | 模拟器构建、个人开发账号真机签名均成功；已安装 |
| iPad 模拟器测试 | 6 项通过：原 PNG/重试 UUID、超限/无效类型拒绝、孤立文件清理、Wire 元数据兼容、分享面板渲染、NSItemProvider → 配对 → 分块传输 → RECEIVED 完整流程 |
| 核心测试 | 28 项通过，新增 PNG 移动、重载、重复接收和后缀输入保护 |
| 浏览器测试 | 46 项通过 |
| Mac 配套构建 | Release 构建及 ad-hoc 签名成功 |
| Swift usbmux 设备发现 | 在本机实际执行，物理 USB 设备发现成功 |
| 真机分享/归档 | 用户确认分享入口出现并能保存到 Mac；本次隔离 USB 检查未取得完整独立收图记录，不将用户反馈写成自动化测试 |

第一次模拟器启动长时间阻塞；恢复后真实协议测试发现测试宿主的 Keychain 结果不适用于配对测试。改为独立临时目录和注入测试凭据，生产代码仍默认使用 Keychain，完整 6 项重新运行通过。未修改生产 Keychain 读写来掩盖该问题。

仍需真机检查：5 张连续分享、传输中拔线、反复开关面板、取消后重试、无目标归档、重新签名后的配对记忆、20MB 截图的内存与能耗。用户反馈一张能传不代表这些全部通过。下一轮先补 Mac 任务管理和手动打断后的恢复，再接入明确的 iPad AI 授权。
