#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
configuration=release
if [[ ${1:-} == --debug ]]; then configuration=debug
elif [[ $# -gt 0 ]]; then print -u2 "Usage: $0 [--debug]"; exit 2; fi
swift build --configuration "$configuration" --disable-sandbox
app_dir="$project_dir/build/Forelock.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/$configuration/Forelock" "$app_dir/Contents/MacOS/Forelock"
cp ".build/$configuration/ForelockNativeHost" "$app_dir/Contents/MacOS/ForelockNativeHost"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ $configuration == debug ]]; then /usr/libexec/PlistBuddy -c "Add :ForelockDiagnosticBuild bool true" "$app_dir/Contents/Info.plist"; fi
mkdir -p "$app_dir/Contents/Frameworks" "$app_dir/Contents/Resources/MediaRemote"
python3 scripts/build-mediaremote.py "$app_dir/Contents/Frameworks/MediaRemoteAdapter.framework"
cp MediaRemote/forelock-nowplaying.pl MediaRemote/REVISION Vendor/MediaRemoteAdapter/LICENSE "$app_dir/Contents/Resources/MediaRemote/"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$app_dir/Contents/MacOS/ForelockNativeHost"
codesign --force --sign - --entitlements Resources/Forelock.entitlements "$app_dir"
codesign --verify --strict "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '\nСобрано: %s\n' "$app_dir"
