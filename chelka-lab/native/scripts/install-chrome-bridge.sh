#!/bin/zsh
set -euo pipefail
app_path=${1:-"$HOME/Applications/Forelock.app"}
host_binary="$app_path/Contents/MacOS/ForelockNativeHost"
if [[ ! -x "$host_binary" ]]; then print -u2 "Сначала соберите и установите Forelock.app: $app_path"; exit 1; fi
python3 - "$host_binary" <<'PY'
import json,sys
from pathlib import Path
binary=Path(sys.argv[1]).resolve()
destination=Path.home()/'Library/Application Support/Google/Chrome/NativeMessagingHosts/com.turbocorn.forelock.music.json'
destination.parent.mkdir(parents=True,exist_ok=True)
manifest={'name':'com.turbocorn.forelock.music','description':'Forelock music metadata and controls','path':str(binary),'type':'stdio','allowed_origins':['chrome-extension://ngdjfmcmoedjlgpahbolpfkhbbfmpeml/']}
destination.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
destination.chmod(0o600)
print('Native Messaging host:',destination)
print('Allowed extension: ngdjfmcmoedjlgpahbolpfkhbbfmpeml')
PY
