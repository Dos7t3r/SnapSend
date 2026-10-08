# SnapSend 架构设计

## 当前实现更新

已由用户真机确认拍照与纯 USB 传图。新一轮改为协议 v2：首次 6 位一次性验证码（60 秒、最多 3 次尝试），长期随机凭据放入钥匙串，后续连接使用 HMAC 挑战验证；不再要求手动输入 32 位密钥。已实现“课程 → 每次上课 → 照片”、Mac 本地时间记录、课程改名、课堂切换与结束、日期/课程搜索、旧照片迁入历史分组，以及手机课堂同步、拍摄时课堂归属、历史筛选、缩放、分享、重新传输、JPEG 质量设置。当前仍未接入媒体帧认证加密、SQLite 与 AI 自动发送。两端需要一起更新；下文为初始方案与阶段记录，以 README 的当前用法为准。

## 目标与当前决策

课堂上，iPhone 拍照并确认后，照片通过纯 USB 到达 Mac，自动投递到指定 ChatGPT Mac App 会话。AI 每次简短确认，下课再总结。不开个人热点，不经过校园网传输手机照片，不建设云端中转，不优先采用 API 独立聊天客户端。用户提及的“路线 C”没有定义；本设计不自行给路线编号。

手机到 Mac 的传输本地化；Mac 向 ChatGPT 发送照片仍需要联网，照片仍会上传给所选 AI 服务。

## 连接选择

纯 Safari 网页不能因插入 USB 自动访问 Mac 的本地网站。iproxy 的常规方向是 Mac 访问 iOS 上监听的服务，不能把它理解成 Safari 到 Mac 的通用反向网络。

第一版使用薄原生 iOS App：SwiftUI 外壳 + UIImagePickerController 系统相机。系统相机拍摄后选择“使用照片”即为发送确认。后续若需要无确认连拍，再改为 AVFoundation 自定义原生拍照界面。

若坚持网页界面，可以让原生 App 在手机本地托管页面、通过 native bridge 接入相机和 USB 队列，但仍需要签名 App，且多了一层生命周期管理，故不作为第一版。

## 系统结构

```text
iOS：系统相机 → 编码/本地持久队列 → 手机监听服务
                                        ⇅ 双向应用协议
                         USB / Apple usbmuxd / iproxy
                                        ⇅
Mac：USB 连接管理 → 验证/落盘 → SQLite 队列 → 自动投递调度器
                                              ↓
                                   ChatGPT Mac App 适配器
                                 辅助功能定位 + 剪贴板图片
                                              ↓
                                  指定会话 / 上传 / 发送
```

USB 连接由 Mac 主动建立：Mac 上 localhost:固定端口经 iproxy 转发到 iPhone App 的监听端口。连接建立后双方均可发消息，手机可主动推送照片。第一版使用 iproxy 子进程作为易调试桥接，确认兼容后再评估直接集成 libusbmuxd（需遵守其 LGPL 许可）。不依赖第三方私有 ChatGPT 接口。

重要验证条件：iPhone 解锁并信任 Mac；App 前台运行；手机监听器实际能被 usbmux 连接；目标 iOS 版本支持此链路。libusbmuxd 的端口代理能力已有项目依据，但本项目还没有完成真机验证。NWListener 的绑定方式以真机实验决定，不先假定 loopback-only 能被 USB 访问。

手机服务即使监听其他接口，也只接受配对鉴权请求；Mac 仅选 USB 设备，关闭 Wi-Fi 设备连接模式。验收时关闭两端 Wi-Fi、手机蜂窝数据与个人热点，确认仍能传图。

## 技术栈与模块

- Mac UI：SwiftUI + AppKit，主窗口、菜单栏、权限引导、课堂列表。
- iOS：SwiftUI + UIKit 系统相机，后续 AVFoundation；ImageIO 做方向校正与编码。
- Mac/iOS 网络：Network.framework，USB 上的分帧双向协议。
- USB：系统 usbmuxd + 开发期 iproxy，独立 Transport 接口。
- 存储：Mac SQLite 与图片文件；iOS 文件队列与 manifest。第一版不需要数据库服务。
- 自动操作：AXUIElement + NSWorkspace + NSPasteboard + 必要的键盘事件。
- 后续浏览器：Chrome/Edge 扩展 + Native Messaging；每个 AI 页面独立 DOM 适配器。Safari 扩展另做兼容。

边界接口：CaptureClient、Transport、PhotoRepository、DeliveryQueue、TargetAdapter。TargetAdapter 提供 inspectTarget、attachImage、waitAttachmentReady、submit、observeSubmission 等动作及能力声明。传输成功与 AI 投递成功完全分开。

## 配对与协议

首次在 Mac 选定 USB 手机，两端显示短配对码；确认后保存随机高熵密钥到 Keychain。短码只用于核对，不作为长期密钥。二维码可选，用于携带配对邀请，不承担 USB 传输。

每次连接使用随机 nonce、协议版本协商及基于密钥的挑战应答。照片帧与控制帧使用成熟加密库提供的认证加密，不自制密码算法；限制帧长度、文件大小、MIME 与解码后像素数。未配对监听器不能读写照片或触发投递。

消息：HELLO、AUTH、SESSION、PHOTO_BEGIN、PHOTO_CHUNK、PHOTO_END、RECEIVED、DELIVERY_STATUS、PING、RESUME。JSON 元数据与二进制块分离，不使用整张照片 base64。

标识包含 sessionID、photoID(UUID)、sequence、captureTime、contentHash、width、height、byteLength。顺序以 session 内 sequence 为准，设备时间用于展示。分块初始 256 KiB，根据真机测量调整。

Mac 写临时文件并验证 hash，原子替换后提交 SQLite 事务，完成后才回 RECEIVED。手机收到确认后可释放传输副本；Mac 保留课堂原始文件。重连查询已接收 photoID 与偏移；上传去重可以实现，但跨第三方 UI 不能承诺“恰好发送一次”。

## 拍照、清晰度与传输

系统相机确认后进入持久队列，马上返回可拍下一张的页面；USB 传输不阻塞下一次拍摄。原图保留在手机队列直到 Mac 接收确认。优先 JPEG；HEIC 在投递前由 Mac 转换，避免各 AI 客户端支持差异。

默认建议文字清晰模式，长边约 3000–4000 像素、JPEG 质量约 0.88，属于待测试参数，不是性能保证。提供原图、文字清晰、快速三档。不因链路是 USB 就压到小图；主要优化方向是减少大文件对 AI 上传速度的影响。

Mac 保留可复习原图与实际投递版本；只对投递版本缩放。自动裁切与透视校正作为后续功能，可预览/撤销，不丢边缘内容。模糊仅提示，第一版不自动拒绝课堂照片。

## ChatGPT Mac App 自动投递

1. 用户手动选择课堂对应的 ChatGPT 会话，SnapSend 绑定 App、窗口与能观察到的会话特征。
2. 开课时先发送一次课堂 prompt，确认提交后允许照片队列自动投递。
3. 新图片到达后，先检查 App 状态、会话特征、输入框是否已有草稿、用户是否正在输入、是否仍在生成，以及附件槽是否可用。
4. 满足条件后短暂激活 ChatGPT，使用 AX 定位输入框、聚焦；保存可保存的剪贴板内容，写入图片类型并粘贴。
5. 等待附件预览与上传就绪信号；不能用固定 sleep 推断上传完成。
6. 再检查目标与草稿，点击可访问的发送按钮。键盘发送只作为经过校准的替代动作。
7. 观察聊天中新的用户消息/附件等证据。区分“已发出操作”“观察到消息”“AI 已回复”。无法观察到证据时标记“发送结果待核实”。

辅助功能权限用于操作目标；如需观察全局输入事件，还可能需要输入监控权限；如采用截图识别兜底，再请求屏幕录制权限。第一版以 AX 为主。实际 ChatGPT 版本是否暴露输入框、附件状态与会话标识，需要本机探测，当前未经验证。

用户开始打字、窗口变化、出现已有草稿时暂停自动投递，避免混入用户文本；自动操作阶段也持续检查用户输入，不能只在开始前检查。尽量恢复先前窗口；剪贴板仅在 changeCount 未被用户更新且内容可还原时恢复。Promise 型剪贴板等内容不能保证完整恢复，需明确显示运行状态。

纯原生 UI 自动投递无法保证完全后台、不抢焦点。若这成为硬要求，改以浏览器扩展投递为优先，并验证网页后台标签的实际行为。

每个目标会话一次只允许一个投递事务。模型生成时排队，不默认点击停止生成。发送失败可以在明确未提交时自动重试；提交后证据丢失不能盲目重发，由用户核实或明确选择重发。页面/App 更新导致定位失败时停队列并提供重新校准。

## 状态与 UI

Mac 主窗口：左侧课堂列表；顶部当前课堂与三个独立状态“手机连接 / 目标 AI / 自动投递”；中间照片时间线；右侧所选照片、投递步骤及错误恢复。菜单栏显示 USB 与队列简况，提供暂停。

iPhone：顶部 USB 连接与目标课堂；中间最近一张的状态；底部大按钮“拍照”，系统相机确认后自动传输；显示待传数与最近三张，可重拍、撤销尚未发送项。成功状态不会弹全屏对话框；断线时继续保存，并明确提示 App 需保持前台。

照片状态：

```text
拍摄确认 → 编码 → 手机已保存 → USB 传输中 → Mac 已保存
       → 等待目标/等待用户空闲/等待 AI 结束
       → 粘贴附件 → 等待上传 → 提交中
       → 已观察到消息 → AI 已确认（有可观察证据时）
```

例外：传输失败、USB 断开、未授权、目标会话改变、已有草稿、登录失效、服务限流、附件上传失败、发送结果待核实、暂停、取消。每个状态包含用户能理解的原因与唯一的下一步，例如“重新连接”“清空或发送草稿”“重新选定会话”“检查是否已发送”。

设计：原生 macOS 侧栏与工具栏，暖灰底色、薄荷绿表示就绪、琥珀表示等待、红色用于需处理故障。状态同时有文字与图标。手机以单手操作、大触控区域、清晰上传反馈为主。预览中的课程与数量为演示数据。

## 课堂 prompt

开课发送一次：

> 你是我的课堂复习助手。这段对话对应一节课。我会按顺序发送板书、课件或笔记图片，通常不附带文字。请结合当前对话中可见的内容理解图片；每次只简短回复“已收到”，如有明显看不清的关键区域，再加一句指出位置。不要立即长篇讲解，也不要编造图片中没有的信息。收到“下课总结”后，再整理知识结构、公式与符号含义、关键例题、易错点和待核实内容。区分课件中的内容和你的补充解释。不要声称已经训练、永久记忆或完整保留所有图片。

下课发送：

> 下课总结。请基于本节课当前可见的图片与对话，按授课顺序整理复习笔记：知识结构、重要定义、公式及适用条件、关键例题步骤、易错点，以及 5 道自测题和参考答案。看不清或上下文缺失的地方请明确标记，不要猜测。

这是利用对话上下文，不是实时训练 AI。长课可能超出上下文或触发上传限制，因此本地完整归档不可省略；必要时按章节分段总结并保存。下课总结排在该课堂照片队列完成之后，待核实项先处理，不能抢在未上传照片前发送。

## 实施顺序与验收

阶段 0：环境与两项技术验证。
- Mac 上编译最小 SwiftUI/AppKit/Network/AX 程序。
- 安装完整 Xcode，完成 iPhone 开发签名与真机运行。
- iOS 前台监听 + Mac iproxy 连接；关闭无线链路，传一张图片并校验 hash；拔线重连且不丢图。
- 探测当前 ChatGPT AX 树，使用测试会话完成附件粘贴、等待上传、提交与证据观察。

阶段 1：单节课闭环。手机系统相机、USB 连接、落盘队列、单目标投递、课堂 prompt、状态及暂停。先确保连续拍照、断线和已有草稿都可恢复。

阶段 2：正式 UI、课堂历史、恢复投递、本地导出、图像档位、菜单栏和结束课堂。

阶段 3：浏览器扩展与其他 AI App 适配器，每个入口单独验证，不承诺所有 App 一套操作通用。

验收必须覆盖：连续 20 张（可分批以匹配 AI 限流）；USB 半途拔线；AI 正在回复；用户正在打字；手动切换会话；附件上传失败；Mac 重启；手机锁屏/后台；发送后崩溃；超长课归档。UI 状态必须与证据对应，不能把“传到 Mac”写成“已发给 AI”。

## 本地环境检查（2026-10-07）

- 项目目录原为空，仅有 Git，未发现项目 AGENTS.md。
- macOS 26.5.1 / Apple Silicon。
- Swift 6.3.2、Command Line Tools 与 macOS SDK 已有。
- 最小 Swift 程序已成功导入并运行 SwiftUI、AppKit、Network、ApplicationServices（AX）；这只验证 Mac 编译环境，不代表自动投递已验证。
- Node 26.0.0、Python 3.14.2、Homebrew 已有。
- ChatGPT.app、Chrome、Edge、Safari 已安装。
- 系统 /var/run/usbmuxd socket 存在。
- 后续已安装 Xcode 27.0 并接受许可，开发路径已切到 /Applications/Xcode.app/Contents/Developer，iPhoneOS 27.0 SDK 可用；模拟器可继续下载，不影响真机 SDK 编译。
- iproxy 与 idevice_id 未在 PATH 中发现。
- 用户提供：iPhone 15 Pro Max / iOS 26.7.1 / 免费 Apple 账号；接受短暂激活 ChatGPT 与剪贴板投递，稳定性优先。设备系统版本为用户提供，未从真机读取。
- 开发者签名、设备连接与辅助功能授权未验证。免费 Personal Team 配置到期后需重新构建安装。

后续已建立 Mac 原型与 iOS 系统相机工程。Mac 构建与两项核心测试通过；iOS 工程通过 iphoneos SDK 的未签名构建。已通过 CoreDevice 检测到物理 iPhone 15 Pro Max 连接。当前实现使用原子 manifest，SQLite 尚未接入；手机 USB 服务、配对加密与自动发送尚未实现。签名安装和纯 USB 真机传图仍未验证。

第二轮修复：手机现在重新加载历史照片并显示缩略图、大图及持久接收状态；使用同一 PendingPhotos 目录兼容旧照片。手机接入回环地址监听服务与 128 位随机开发连接密钥，Mac 自动启动 iproxy 的 USB 模式，握手后按顺序传图，落盘后确认。照片确认后不删除。未确认项重连整张重传，尚非按字节断点续传。密钥当前存放手机 App 偏好设置；Keychain 与认证加密仍待接入。四项核心测试通过，iOS 签名构建通过；真机安装时设备不可用，正在等待手机重新连接解锁后验证。AI 自动投递仍未实现。

## 依据

- USB 端口代理：https://github.com/libimobiledevice/libusbmuxd
- 系统相机：https://developer.apple.com/documentation/uikit/uiimagepickercontroller
- 辅助功能：https://developer.apple.com/documentation/applicationservices/axuielement
- 免费签名周期：https://developer.apple.com/help/account/basics/about-your-developer-account
- HTML 拍摄规范：https://www.w3.org/TR/html-media-capture/
- 浏览器扩展本地桥接：https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging


## v0.2 投递实现进度（当前事实，前文阶段记录仅为历史）

USB v2、六位首配、课程/课堂和真机接收已接入。新增 DeliveryLedger 原子持久队列、ChatGPT 网页 MV3 扩展、stdio Native Messaging 宿主、Mac 回环 token 服务与逐步操作引导。发送准备或提交中崩溃会转为 uncertain，由用户核对后重排；sent 不可自动重排。仅在明确绑定当前课堂、正确标签页 URL、前台窗口和空草稿时取队列。提交之前 Mac 先持久记录 submitting，然后扩展点击；观察新用户图片消息后才记录 sent。超时不重复提交。

网页上传副本 2048px，原图归档保持不变。现先适配 ChatGPT 网页；其他 AI 需独立 DOM 适配。原生 AX 入口有权限/窗口/草稿/附件检查，但服务器回执不可可靠验证，因此提交后暂停核对；连续无人值守的原生投递未完成。实际 Chrome/ChatGPT 发图验收尚未完成（本轮 CUA 无法连接 Chrome）。详见 README 的完整安装与验收步骤。

Chrome 文档依据：
- https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts
- https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle
