#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# This window uses synthetic logo photos, temporary storage, and a simulated
# bridge heartbeat. It never starts the real USB server or Chrome native host.
scripts/check-workspace.sh
python3 - <<'PY'
from pathlib import Path
import plistlib
import shutil
root = Path('build/MacInteractionQA.app/Contents')
(root / 'MacOS').mkdir(parents=True, exist_ok=True)
(root / 'Resources').mkdir(exist_ok=True)
shutil.copy2('build/render-mac', root / 'MacOS/InteractionQA')
shutil.copy2('assets/brand/SnapMark.png', root / 'Resources/SnapMark.png')
(root / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.snapsend.tests.interaction',
    'CFBundleName': 'SnapSend Interaction QA',
    'CFBundleExecutable': 'InteractionQA',
    'CFBundlePackageType': 'APPL',
    'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
}))
PY
codesign --force --sign - build/MacInteractionQA.app
open build/MacInteractionQA.app --args --interactive
