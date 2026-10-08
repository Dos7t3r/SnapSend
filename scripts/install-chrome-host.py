#!/usr/bin/env python3
"""Register the bundled native host for this extension only. No browser profile edits."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
app = root / 'build/SnapSend.app'
host = app / 'Contents/MacOS/SnapSendNativeHost'
extension = app / 'Contents/Resources/chrome-extension'
id = (extension / 'extension-id.txt').read_text().strip()
assert host.is_file() and len(id) == 32 and all('a' <= c <= 'p' for c in id)
folder = Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts'
folder.mkdir(parents=True, exist_ok=True)
manifest = {'name':'com.snapsend.bridge','description':'SnapSend local photo bridge','path':str(host),'type':'stdio','allowed_origins':[f'chrome-extension://{id}/']}
file = folder / 'com.snapsend.bridge.json'
file.write_text(json.dumps(manifest,indent=2)+'\n')
print('Chrome bridge registered for the bundled SnapSend extension only.')
