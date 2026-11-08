#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
backup_dir="$project_dir/artifacts/rollback-0.5.0/Forelock.app"
installed_dir="$HOME/Applications/Forelock.app"
if [[ ! -d "$backup_dir" ]]; then print -u2 'Локальная копия 0.5.0 не найдена. Соберите feature/file-drop-2 отдельно.'; exit 1; fi
if [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$backup_dir/Contents/Info.plist") != '0.5.0' ]]; then print -u2 'Неверная версия резервной копии'; exit 1; fi
codesign --verify --deep --strict "$backup_dir"
if pgrep -x Forelock >/dev/null; then
    print -u2 'Сначала завершите Forelock через его меню. Повторите эту команду после выхода.'; exit 1
else
    process_status=$?
    if (( process_status != 1 )); then print -u2 'Не удалось проверить запущенный процесс; откат остановлен.'; exit 1; fi
fi
if [[ -d "$installed_dir" ]]; then
    saved_dir=$(mktemp -d "$project_dir/artifacts/replaced-experimental.XXXXXX")
    mv "$installed_dir" "$saved_dir/Forelock.app"
fi
ditto "$backup_dir" "$installed_dir"
codesign --verify --deep --strict "$installed_dir"
print 'Восстановлен Forelock 0.5.0. Откройте ~/Applications/Forelock.app.'
