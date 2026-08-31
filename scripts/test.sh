#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
export CLANG_MODULE_CACHE_PATH="${project_root}/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${project_root}/.build/swiftpm-module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFTPM_MODULECACHE_OVERRIDE}"

swift test --package-path "${project_root}" --disable-sandbox
/usr/bin/plutil -lint "${project_root}/Resources/com.example.safeclam.helper.plist"
/usr/bin/plutil -lint "${project_root}/Resources/com.example.safeclam.supervisor.plist"
/usr/bin/plutil -lint "${project_root}/Packaging/SafeClam.app.Info.plist"
"${script_dir}/test-release-tools.sh"

print "단위 테스트, plist와 release 입력 gate 검증 통과"
