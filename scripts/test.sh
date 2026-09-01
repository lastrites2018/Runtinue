#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
export CLANG_MODULE_CACHE_PATH="${project_root}/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${project_root}/.build/swiftpm-module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFTPM_MODULECACHE_OVERRIDE}"

swift test --package-path "${project_root}" --disable-sandbox
/usr/bin/plutil -lint "${project_root}/Resources/io.github.lastrites2018.runtinue.helper.plist"
/usr/bin/plutil -lint "${project_root}/Resources/io.github.lastrites2018.runtinue.supervisor.plist"
/usr/bin/plutil -lint "${project_root}/Packaging/Runtinue.app.Info.plist"
"${script_dir}/test-release-tools.sh"
"${script_dir}/test-install-preflight.sh"
/bin/zsh "${script_dir}/test-version.sh"
/bin/zsh "${script_dir}/test-hardware-validation.sh"

print "단위 테스트, plist, 버전, release 입력, 설치 전 검사와 실기기 기록 gate 통과"
