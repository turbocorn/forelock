#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
swift test --disable-sandbox --cache-path "$project_dir/.build/package-cache"
