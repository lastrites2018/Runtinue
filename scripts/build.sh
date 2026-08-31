#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
release_root=${SAFECLAM_RELEASE_ROOT:-"${project_root}/.release"}
distribution_root="${release_root}/distribution"
version=${VERSION:-0.1.0}
build_number=${BUILD_NUMBER:-1}
application_identity=${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION을 지정해야 합니다}

[[ "${version}" =~ '^[0-9]+([.][0-9]+){1,3}$' ]] || {
  print -u2 "VERSION 형식이 올바르지 않음"
  exit 64
}
[[ "${build_number}" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "BUILD_NUMBER는 양의 정수여야 합니다"
  exit 64
}

project_root_abs=${project_root:A}
release_root_abs=${release_root:A}
case "${release_root_abs}" in
  "${project_root_abs}"/*) ;;
  *) print -u2 "SAFECLAM_RELEASE_ROOT는 프로젝트 내부의 하위 경로여야 합니다"; exit 64 ;;
esac
[[ "${release_root_abs}" != "${project_root_abs}" ]] || {
  print -u2 "SAFECLAM_RELEASE_ROOT로 프로젝트 루트를 사용할 수 없습니다"
  exit 64
}
release_root="${release_root_abs}"
distribution_root="${release_root}/distribution"

for tool in swift codesign csreq ditto; do
  command -v "${tool}" >/dev/null || {
    print -u2 "필수 도구를 찾을 수 없음: ${tool}"
    exit 69
  }
done

mkdir -p "${release_root}"
rm -rf -- "${distribution_root}"
mkdir -p "${distribution_root}/bin" "${distribution_root}/requirements"

export CLANG_MODULE_CACHE_PATH="${project_root}/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${project_root}/.build/swiftpm-module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFTPM_MODULECACHE_OVERRIDE}"

swift build --package-path "${project_root}" -c release --disable-sandbox
swift_bin=$(swift build --package-path "${project_root}" -c release --show-bin-path --disable-sandbox)

for binary in safeclam safeclam-helper safeclam-supervisor safeclam-hook safeclam-activity; do
  test -x "${swift_bin}/${binary}" || {
    print -u2 "빌드 산출물이 없음: ${binary}"
    exit 66
  }
  /usr/bin/ditto "${swift_bin}/${binary}" "${distribution_root}/bin/${binary}"
done

app_root="${distribution_root}/SafeClam.app"
mkdir -p "${app_root}/Contents/MacOS"
/usr/bin/ditto "${project_root}/Packaging/SafeClam.app.Info.plist" "${app_root}/Contents/Info.plist"
/usr/bin/ditto "${swift_bin}/safeclam-menubar" "${app_root}/Contents/MacOS/safeclam-menubar"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${app_root}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_number}" "${app_root}/Contents/Info.plist"

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

sign_binary "${distribution_root}/bin/safeclam" "com.example.safeclam.cli"
sign_binary "${distribution_root}/bin/safeclam-helper" "com.example.safeclam.helper"
sign_binary "${distribution_root}/bin/safeclam-supervisor" "com.example.safeclam.supervisor"
sign_binary "${distribution_root}/bin/safeclam-hook" "com.example.safeclam.hook"
sign_binary "${distribution_root}/bin/safeclam-activity" "com.example.safeclam.activity"
sign_binary "${app_root}/Contents/MacOS/safeclam-menubar" "com.example.safeclam.app"
app_timestamp_args=()
if [[ "${application_identity}" != "-" ]]; then
  app_timestamp_args=(--timestamp)
fi
/usr/bin/codesign --force "${app_timestamp_args[@]}" --options runtime \
  --sign "${application_identity}" --identifier "com.example.safeclam.app" "${app_root}"
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

supervisor_requirement=$(designated_requirement "${distribution_root}/bin/safeclam-supervisor")
cli_requirement=$(designated_requirement "${distribution_root}/bin/safeclam")
app_requirement=$(designated_requirement "${app_root}")
hook_requirement=$(designated_requirement "${distribution_root}/bin/safeclam-hook")
activity_requirement=$(designated_requirement "${distribution_root}/bin/safeclam-activity")

print -r -- "${supervisor_requirement}" > "${distribution_root}/requirements/supervisor.requirement"
print -r -- "(${cli_requirement}) or (${app_requirement})" > "${distribution_root}/requirements/control.requirement"
print -r -- "(${hook_requirement}) or (${activity_requirement})" > "${distribution_root}/requirements/activity.requirement"
chmod 0600 "${distribution_root}/requirements/supervisor.requirement"
chmod 0644 "${distribution_root}/requirements/control.requirement" "${distribution_root}/requirements/activity.requirement"

/usr/bin/csreq -r="${supervisor_requirement}" -t >/dev/null
/usr/bin/csreq -r="(${cli_requirement}) or (${app_requirement})" -t >/dev/null
/usr/bin/csreq -r="(${hook_requirement}) or (${activity_requirement})" -t >/dev/null
/usr/bin/codesign --verify --strict -R="${supervisor_requirement}" \
  "${distribution_root}/bin/safeclam-supervisor"
/usr/bin/codesign --verify --strict -R="(${cli_requirement}) or (${app_requirement})" \
  "${distribution_root}/bin/safeclam"
/usr/bin/codesign --verify --strict -R="(${cli_requirement}) or (${app_requirement})" \
  "${app_root}"
/usr/bin/codesign --verify --strict -R="(${hook_requirement}) or (${activity_requirement})" \
  "${distribution_root}/bin/safeclam-hook"
/usr/bin/codesign --verify --strict -R="(${hook_requirement}) or (${activity_requirement})" \
  "${distribution_root}/bin/safeclam-activity"

print "서명된 배포 트리 생성: ${distribution_root}"
