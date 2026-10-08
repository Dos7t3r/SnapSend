# v0.5.0 发布记录

日期：2026-10-07。首个公开版本，MIT 许可。

## 交付

- `SnapSend-Mac-arm64.zip`：Apple Silicon Release 应用，含浏览器桥接、插件、品牌资源及 MIT 文本。ad-hoc 签名、未公证；USB 依赖 libusbmuxd 不随包分发。
- `SnapSend-Chrome-Extension.zip`：独立插件，固定公开 key/扩展 ID、安装说明与 MIT 文本。
- `SnapSend-iOS-Source.zip`：iPhone 工程、共享代码、文档和 MIT 文本；不含作者本地签名配置、证书或设备描述文件。
- `SHA256SUMS.txt`：以上三个文件的 SHA-256；下载后在同一目录运行 `shasum -a 256 -c SHA256SUMS.txt`。

GitHub Release 自带完整仓库源码压缩包；仓库源码与下载资产都不包含用户照片、钥匙串凭据、`.env` 或生成构建日志。

## 验证记录

| 检查 | 实际结果 |
| --- | --- |
| Swift 核心回归 | 16 项通过，0 失败 |
| Node 浏览器回归 | 37 项通过，0 失败 |
| iOS 模拟器回归 | 4 项通过，0 失败；结果无运行时警告 |
| iPhone Release 构建/安装 | 在原应用标识下覆盖安装并成功启动；未卸载 |
| 公开 iOS 工程 Release 构建 | 无签名、无作者 Team ID 的通用 iOS 构建通过 |
| Mac Release | 编译、打包、解压后签名检查通过 |
| 回环桥接集成 | 隔离 DEBUG 宿主：token 门禁、0600 权限、连续两帧及最大响应通过 |
| 解压后 iOS 源码 | 无本地签名配置的 Release 构建通过 |
| 下载包检查 | 三个 ZIP 完整性、许可证、插件引用资源及签名材料排除检查通过 |

构建环境：macOS 26.7.1、Xcode 27.0（27A266a）、arm64；模拟器为 iPhone 18 Pro Max / iOS 27。真机安装为 iPhone 15 Pro Max。

### 可复现命令

```sh
swift test --scratch-path build/swift --cache-path build/cache --config-path build/config --security-path build/security --disable-sandbox
node --test Tests/Browser/*.test.cjs
xcodebuild -project iOS/SnapSendPhone.xcodeproj -scheme SnapSendPhone -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/public-ios CODE_SIGNING_ALLOWED=NO SNAPSEND_DEVELOPMENT_TEAM= build
zsh scripts/package-release.sh
```

如需模拟器检查，使用 README 中的 GalleryTests 命令。回环桥接集成检查使用 DEBUG 测试宿主和隔离临时端点；Release 宿主不接受测试端点环境变量，防止测试错误连接真实用户桥接：

```sh
swiftc -parse-as-library -module-cache-path build/module-cache Sources/SnapSend/BrowserBridge.swift Tests/Browser/bridge-main.swift -o build/bridge-test
swiftc -O -DDEBUG -module-cache-path build/module-cache Sources/SnapSendNativeHost/main.swift -o build/native-host-test
python3 Tests/Browser/bridge.test.py
```

## 未验证范围

测试用模拟网页/Chrome API 与隔离图片。最新版真实 USB→AI 连续发图、AI 网页后续改版、真实设备续航与内存、旧系统及 Intel 均未完成验收。真机安装成功只表示签名、安装及启动通过，不代表上述场景都已通过。

原始开发日志包含本机路径及签名信息，未作为公共附件上传；这里记录的是对外可复现的检查及结论。
