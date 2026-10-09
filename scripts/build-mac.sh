#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p build/module-cache build/cache build/config build/security
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache"
swift build -c release --scratch-path build/swift --cache-path build/cache --config-path build/config --security-path build/security --disable-sandbox
snapsend_bin_dir=$(swift build -c release --scratch-path build/swift --cache-path build/cache --config-path build/config --security-path build/security --disable-sandbox --show-bin-path)
mkdir -p build/SnapSend.app/Contents/MacOS
cp "$snapsend_bin_dir/SnapSend" build/SnapSend.app/Contents/MacOS/SnapSend
cp "$snapsend_bin_dir/SnapSendNativeHost" build/SnapSend.app/Contents/MacOS/SnapSendNativeHost
mkdir -p build/SnapSend.app/Contents/Resources
cp assets/brand/SnapMark.png build/SnapSend.app/Contents/Resources/SnapMark.png
cp assets/brand/SnapSend.icns build/SnapSend.app/Contents/Resources/SnapSend.icns
cp LICENSE build/SnapSend.app/Contents/Resources/LICENSE
rm -rf build/SnapSend.app/Contents/Resources/chrome-extension
cp -R chrome-extension build/SnapSend.app/Contents/Resources/chrome-extension
codesign --force --sign - build/SnapSend.app/Contents/MacOS/SnapSendNativeHost
cat > build/SnapSend.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.snapsend.prototype.mac</string>
<key>CFBundleName</key><string>SnapSend</string>
<key>CFBundleExecutable</key><string>SnapSend</string>
<key>CFBundleIconFile</key><string>SnapSend</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>10</string>
<key>CFBundleShortVersionString</key><string>0.6.2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - build/SnapSend.app
print "Built: $PWD/build/SnapSend.app"
