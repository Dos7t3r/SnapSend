#!/usr/bin/env python3
"""Package public extension/iOS sources only; never include signing or user data."""
import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
output = root / 'dist'
output.mkdir(exist_ok=True)

def public_file(path):
    relative = path.relative_to(root)
    return (path.is_file() and not any(p in {'xcuserdata', '.DS_Store', 'build', '.git'} for p in relative.parts)
            and path.name != 'Signing.local.xcconfig'
            and path.suffix.lower() not in {'.mobileprovision', '.provisionprofile', '.p12', '.p8', '.cer', '.key', '.ipa', '.xcuserstate'})

def add(archive, path, prefix):
    if public_file(path):
        archive.write(path, str(Path(prefix) / path.relative_to(root)))

manifest = json.loads((root / 'chrome-extension/manifest.json').read_text())
with zipfile.ZipFile(output / 'SnapSend-Chrome-Extension.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((root / 'chrome-extension').rglob('*')):
        if public_file(path):
            archive.write(path, 'SnapSend-Chrome-Extension/' + str(path.relative_to(root / 'chrome-extension')))
    archive.write(root / 'LICENSE', 'SnapSend-Chrome-Extension/LICENSE')
    archive.writestr('SnapSend-Chrome-Extension/INSTALL.md',
                     '# 当前扩展包\n\n版本：' + manifest['version'] +
                     '。请配合对应 Mac 开发版；下方公开下载链接可能仍指向上一稳定版本。\n\n' +
                     (root / 'downloads/README.md').read_text())

with zipfile.ZipFile(output / 'SnapSend-iOS-Source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for directory in ['iOS', 'Sources/SnapSendCore']:
        for path in sorted((root / directory).rglob('*')):
            add(archive, path, 'SnapSend-iOS-Source')
    for file in ['Sources/SnapSend/SnapTheme.swift', 'Sources/SnapSend/ThumbnailLoader.swift', 'README.md', 'LICENSE', 'CHANGELOG.md']:
        add(archive, root / file, 'SnapSend-iOS-Source')
    for path in sorted((root / 'docs').rglob('*')):
        add(archive, path, 'SnapSend-iOS-Source')
    for path in sorted((root / 'downloads').rglob('*')):
        add(archive, path, 'SnapSend-iOS-Source')
    add(archive, root / 'assets/screenshots/mac-workspace.png', 'SnapSend-iOS-Source')

with zipfile.ZipFile(output / 'SnapSend-iPad-Source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for directory in ['iPad', 'Sources/SnapSendCore']:
        for path in sorted((root / directory).rglob('*')):
            add(archive, path, 'SnapSend-iPad-Source')
    for file in ['iOS/Signing.xcconfig', 'iOS/Signing.local.xcconfig.example', 'Sources/SnapSend/SnapTheme.swift', 'README.md', 'LICENSE', 'CHANGELOG.md']:
        add(archive, root / file, 'SnapSend-iPad-Source')
    for path in sorted((root / 'docs').rglob('*')):
        add(archive, path, 'SnapSend-iPad-Source')

names = ['SnapSend-Mac-arm64.zip', 'SnapSend-Chrome-Extension.zip', 'SnapSend-iOS-Source.zip', 'SnapSend-iPad-Source.zip']
checksums = []
for name in names:
    path = output / name
    if not path.is_file():
        raise SystemExit('Missing release asset: ' + name)
    checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + name)
(output / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n')
print('Packaged version ' + manifest['version'] + ': ' + ', '.join(names))
