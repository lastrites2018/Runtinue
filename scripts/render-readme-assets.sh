#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
export CLANG_MODULE_CACHE_PATH="${project_root}/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${project_root}/.build/swiftpm-module-cache"
export RUNTINUE_RENDER_README_ASSETS=1
export RUNTINUE_README_ASSET_ROOT="${project_root}/READMEAssets"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFTPM_MODULECACHE_OVERRIDE}"

swift test --package-path "${project_root}" --disable-sandbox \
  --filter READMEAssetRenderingTests.testRenderREADMEStatusAssetsFromProductionViews

print "README 상태 이미지 2개를 실제 앱 컴포넌트와 고정 예시 데이터로 갱신했습니다."
