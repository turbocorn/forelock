#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
swift build --configuration release --disable-sandbox
app_dir="$project_dir/build/Forelock.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/Forelock "$app_dir/Contents/MacOS/Forelock"
cp .build/release/ForelockNativeHost "$app_dir/Contents/MacOS/ForelockNativeHost"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$app_dir/Contents/MacOS/ForelockNativeHost"
codesign --force --sign - --entitlements Resources/Forelock.entitlements "$app_dir"
codesign --verify --strict "$app_dir"
printf '\nСобрано: %s\n' "$app_dir"
