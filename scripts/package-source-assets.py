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
    archive.write(root / 'downloads/README.md', 'SnapSend-Chrome-Extension/INSTALL.md')

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

names = ['SnapSend-Mac-arm64.zip', 'SnapSend-Chrome-Extension.zip', 'SnapSend-iOS-Source.zip']
checksums = []
for name in names:
    path = output / name
    if not path.is_file():
        raise SystemExit('Missing release asset: ' + name)
    checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + name)
(output / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n')
print('Packaged version ' + manifest['version'] + ': ' + ', '.join(names))
