#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
release_root=${RUNTINUE_RELEASE_ROOT:-"${project_root}/.release"}
distribution_root="${release_root}/distribution"
version=$(/bin/zsh "${script_dir}/version.sh")
build_number=${BUILD_NUMBER:-1}
application_identity=${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION을 지정해야 합니다}

[[ "${build_number}" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "BUILD_NUMBER는 양의 정수여야 합니다"
  exit 64
}

project_root_abs=${project_root:A}
release_root_abs=${release_root:A}
case "${release_root_abs}" in
  "${project_root_abs}"/*) ;;
  *) print -u2 "RUNTINUE_RELEASE_ROOT는 프로젝트 내부의 하위 경로여야 합니다"; exit 64 ;;
esac
[[ "${release_root_abs}" != "${project_root_abs}" ]] || {
  print -u2 "RUNTINUE_RELEASE_ROOT로 프로젝트 루트를 사용할 수 없습니다"
  exit 64
}
release_root="${release_root_abs}"
distribution_root="${release_root}/distribution"

[[ "$(/usr/bin/uname -m)" == arm64 ]] || {
  print -u2 "Runtinue 패키지는 Apple Silicon의 네이티브 arm64 환경에서 빌드해야 합니다"
  exit 65
}

for tool in swift codesign csreq ditto sips iconutil lipo; do
  command -v "${tool}" >/dev/null || {
    print -u2 "필수 도구를 찾을 수 없음: ${tool}"
    exit 69
  }
done

source_commit=$(/usr/bin/git -C "${project_root}" rev-parse --verify HEAD)
source_dirty=false
if ! /usr/bin/git -C "${project_root}" diff --quiet HEAD -- || \
  [[ -n "$(/usr/bin/git -C "${project_root}" ls-files --others --exclude-standard)" ]]; then
  source_dirty=true
fi

mkdir -p "${release_root}"
rm -rf -- "${distribution_root}"
mkdir -p "${distribution_root}/bin" "${distribution_root}/requirements"

export CLANG_MODULE_CACHE_PATH="${project_root}/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${project_root}/.build/swiftpm-module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFTPM_MODULECACHE_OVERRIDE}"

swift build --package-path "${project_root}" -c release --arch arm64 --disable-sandbox
swift_bin=$(swift build --package-path "${project_root}" -c release --arch arm64 --show-bin-path --disable-sandbox)

for binary in runtinue runtinue-helper runtinue-supervisor runtinue-hook runtinue-activity; do
  test -x "${swift_bin}/${binary}" || {
    print -u2 "빌드 산출물이 없음: ${binary}"
    exit 66
  }
  /usr/bin/ditto "${swift_bin}/${binary}" "${distribution_root}/bin/${binary}"
done

app_root="${distribution_root}/Runtinue.app"
mkdir -p "${app_root}/Contents/MacOS" "${app_root}/Contents/Resources"
/usr/bin/ditto "${project_root}/Packaging/Runtinue.app.Info.plist" "${app_root}/Contents/Info.plist"
/usr/bin/ditto "${swift_bin}/runtinue-menubar" "${app_root}/Contents/MacOS/runtinue-menubar"
/usr/bin/ditto "${project_root}/Sources/RuntinueMenuBar/Resources/RuntinueTemplate.png" \
  "${app_root}/Contents/Resources/RuntinueTemplate.png"

iconset_root="${distribution_root}/Runtinue.iconset"
mkdir -p "${iconset_root}"
for icon_size in 16 32 128 256 512; do
  /usr/bin/sips -z "${icon_size}" "${icon_size}" "${project_root}/Packaging/RuntinueIcon.png" \
    --out "${iconset_root}/icon_${icon_size}x${icon_size}.png" >/dev/null
  retina_size=$((icon_size * 2))
  /usr/bin/sips -z "${retina_size}" "${retina_size}" "${project_root}/Packaging/RuntinueIcon.png" \
    --out "${iconset_root}/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output "${app_root}/Contents/Resources/Runtinue.icns" "${iconset_root}" || {
  print -u2 "iconutil 변환 실패. Xcode asset catalog compiler로 다시 시도합니다"
  actool=$(/usr/bin/xcrun --find actool 2>/dev/null) || {
    print -u2 "iconutil fallback에 필요한 actool을 찾을 수 없습니다"
    exit 69
  }
  asset_catalog_root="${distribution_root}/Runtinue.xcassets"
  app_icon_root="${asset_catalog_root}/Runtinue.appiconset"
  asset_output_root="${distribution_root}/asset-output"
  rm -rf -- "${asset_catalog_root}" "${asset_output_root}"
  mkdir -p "${asset_catalog_root}" "${app_icon_root}" "${asset_output_root}"
  /usr/bin/ditto "${project_root}/Packaging/Runtinue.xcassets/Contents.json" \
    "${asset_catalog_root}/Contents.json"
  /usr/bin/ditto "${project_root}/Packaging/Runtinue.xcassets/Runtinue.appiconset/Contents.json" \
    "${app_icon_root}/Contents.json"
  for icon in "${iconset_root}"/*.png; do
    /usr/bin/ditto "${icon}" "${app_icon_root}/${icon:t}"
  done
  "${actool}" \
    --compile "${asset_output_root}" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon Runtinue \
    --output-partial-info-plist "${distribution_root}/Runtinue.asset-info.plist" \
    "${asset_catalog_root}" >/dev/null
  [[ -f "${asset_output_root}/Runtinue.icns" ]] || {
    print -u2 "actool이 Runtinue.icns를 생성하지 않았습니다"
    exit 66
  }
  /usr/bin/ditto "${asset_output_root}/Runtinue.icns" \
    "${app_root}/Contents/Resources/Runtinue.icns"
}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${app_root}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_number}" "${app_root}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :RuntinueSourceCommit ${source_commit}" "${app_root}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :RuntinueSourceDirty ${source_dirty}" "${app_root}/Contents/Info.plist"

for binary in \
  "${distribution_root}/bin/runtinue" "${distribution_root}/bin/runtinue-helper" \
  "${distribution_root}/bin/runtinue-supervisor" "${distribution_root}/bin/runtinue-hook" \
  "${distribution_root}/bin/runtinue-activity" "${app_root}/Contents/MacOS/runtinue-menubar"; do
  [[ "$(/usr/bin/lipo -archs "${binary}")" == arm64 ]] || {
    print -u2 "arm64 전용 빌드 산출물이 아닙니다: ${binary}"
    exit 65
  }
done

sign_binary() {
  local path=$1
  local identifier=$2
  local timestamp_args=()
  if [[ "${application_identity}" != "-" ]]; then
    timestamp_args=(--timestamp)
  fi
  /usr/bin/codesign --force "${timestamp_args[@]}" --options runtime \
    --sign "${application_identity}" --identifier "${identifier}" "${path}"
  /usr/bin/codesign --verify --strict --verbose=2 "${path}"
}

sign_binary "${distribution_root}/bin/runtinue" "io.github.lastrites2018.runtinue.cli"
sign_binary "${distribution_root}/bin/runtinue-helper" "io.github.lastrites2018.runtinue.helper"
sign_binary "${distribution_root}/bin/runtinue-supervisor" "io.github.lastrites2018.runtinue.supervisor"
sign_binary "${distribution_root}/bin/runtinue-hook" "io.github.lastrites2018.runtinue.hook"
sign_binary "${distribution_root}/bin/runtinue-activity" "io.github.lastrites2018.runtinue.activity"
sign_binary "${app_root}/Contents/MacOS/runtinue-menubar" "io.github.lastrites2018.runtinue.app"
app_timestamp_args=()
if [[ "${application_identity}" != "-" ]]; then
  app_timestamp_args=(--timestamp)
fi
/usr/bin/codesign --force "${app_timestamp_args[@]}" --options runtime \
  --sign "${application_identity}" --identifier "io.github.lastrites2018.runtinue.app" "${app_root}"
/usr/bin/codesign --verify --strict --verbose=2 "${app_root}"

designated_requirement() {
  local path=$1
  local requirement
  requirement=$(
    /usr/bin/codesign -d -r- "${path}" 2>&1 \
      | /usr/bin/sed -n -e 's/^designated => //p' -e 's/^# designated => //p'
  )
  test -n "${requirement}" || {
    print -u2 "designated requirement 추출 실패: ${path}"
    exit 65
  }
  print -r -- "${requirement}"
}

supervisor_requirement=$(designated_requirement "${distribution_root}/bin/runtinue-supervisor")
cli_requirement=$(designated_requirement "${distribution_root}/bin/runtinue")
app_requirement=$(designated_requirement "${app_root}")
hook_requirement=$(designated_requirement "${distribution_root}/bin/runtinue-hook")
activity_requirement=$(designated_requirement "${distribution_root}/bin/runtinue-activity")

print -r -- "${supervisor_requirement}" > "${distribution_root}/requirements/supervisor.requirement"
print -r -- "(${cli_requirement}) or (${app_requirement})" > "${distribution_root}/requirements/control.requirement"
print -r -- "(${hook_requirement}) or (${activity_requirement})" > "${distribution_root}/requirements/activity.requirement"
chmod 0600 "${distribution_root}/requirements/supervisor.requirement"
chmod 0644 "${distribution_root}/requirements/control.requirement" "${distribution_root}/requirements/activity.requirement"

/usr/bin/csreq -r="${supervisor_requirement}" -t >/dev/null
/usr/bin/csreq -r="(${cli_requirement}) or (${app_requirement})" -t >/dev/null
/usr/bin/csreq -r="(${hook_requirement}) or (${activity_requirement})" -t >/dev/null
/usr/bin/codesign --verify --strict -R="${supervisor_requirement}" \
  "${distribution_root}/bin/runtinue-supervisor"
/usr/bin/codesign --verify --strict -R="(${cli_requirement}) or (${app_requirement})" \
  "${distribution_root}/bin/runtinue"
/usr/bin/codesign --verify --strict -R="(${cli_requirement}) or (${app_requirement})" \
  "${app_root}"
/usr/bin/codesign --verify --strict -R="(${hook_requirement}) or (${activity_requirement})" \
  "${distribution_root}/bin/runtinue-hook"
/usr/bin/codesign --verify --strict -R="(${hook_requirement}) or (${activity_requirement})" \
  "${distribution_root}/bin/runtinue-activity"

print "서명된 배포 트리 생성: ${distribution_root}"
