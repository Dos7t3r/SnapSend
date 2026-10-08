#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p build/module-cache
python3 - <<'PY'
from pathlib import Path
Path('build/RenderModel.swift').write_text(Path('Sources/SnapSend/SnapSendApp.swift').read_text().replace('@main\nstruct SnapSendApp', 'struct SnapSendApp'))
PY
sources=(build/RenderModel.swift Sources/SnapSend/WorkspaceView.swift Sources/SnapSend/SnapTheme.swift Sources/SnapSend/ThumbnailLoader.swift Sources/SnapSend/BrowserBridge.swift Sources/SnapSend/NativeDelivery.swift Sources/SnapSend/Theme/*.swift Sources/SnapSend/Components/*.swift Sources/SnapSend/Screens/*.swift)
objects=(build/swift/out/Intermediates.noindex/SnapSend.build/Debug/SnapSendCore-t.build/Objects-normal/arm64/*.o)
for fixture in workspace-integration render-mac; do
  swiftc -O -DWORKSPACE_FIXTURES -swift-version 6 -parse-as-library -module-cache-path build/module-cache -I build/swift/out/Products/Debug $sources Tests/Visual/$fixture.swift $objects -o build/$fixture
  build/$fixture
done
