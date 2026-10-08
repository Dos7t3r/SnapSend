#!/bin/zsh
set -eu
cd "${0:A:h}/.."
zsh scripts/build-mac.sh
mkdir -p dist
codesign --verify --deep --strict build/SnapSend.app
ditto -c -k --sequesterRsrc --keepParent build/SnapSend.app dist/SnapSend-Mac-arm64.zip
python3 scripts/package-source-assets.py
print "Release assets: $PWD/dist"
