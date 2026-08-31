#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
pkg=${1:-}
test -n "${pkg}" && test -f "${pkg}" || {
  print -u2 "사용법: verify-package-payload.sh <SafeClam.pkg>"
  exit 64
}

work_root=$(/usr/bin/mktemp -d /tmp/safeclam-package-payload.XXXXXX)
cleanup() {
  /bin/rm -rf -- "${work_root}"
}
trap cleanup EXIT
/usr/sbin/pkgutil --expand-full "${pkg}" "${work_root}/expanded"
payload_candidates=("${work_root}/expanded"/*/Payload(N))
if [[ ${#payload_candidates[@]} -ne 1 ]]; then
  print -u2 "패키지에서 단일 payload를 찾지 못함"
  exit 66
fi
payload=${payload_candidates[1]}
package_scripts=${payload:h}/Scripts

required_paths=(
  "${payload}/usr/local/bin/safeclam"
  "${payload}/usr/local/bin/safeclam-hook"
  "${payload}/usr/local/bin/safeclam-activity"
  "${payload}/Library/Application Support/com.example.safeclam/bin/safeclam-helper"
  "${payload}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
  "${payload}/Applications/SafeClam.app"
  "${payload}/Library/LaunchDaemons/com.example.safeclam.helper.plist"
  "${payload}/Library/LaunchAgents/com.example.safeclam.supervisor.plist"
)
for path in "${required_paths[@]}"; do
  test -e "${path}" || {
    print -u2 "패키지 payload 누락: ${path}"
    exit 66
  }
done

app_info="${payload}/Applications/SafeClam.app/Contents/Info.plist"
location_usage=$(
  /usr/bin/plutil -extract NSLocationUsageDescription raw "${app_info}"
)
test -n "${location_usage}" || {
  print -u2 "패키지 앱에 Wi-Fi 감지용 위치 권한 설명이 없음"
  exit 66
}
app_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw "${app_info}"
)
[[ "${app_identifier}" == "com.example.safeclam.app" ]] || {
  print -u2 "패키지 앱 identifier가 예상과 다름"
  exit 66
}

expect_plist_value() {
  local plist=$1
  local key=$2
  local expected=$3
  local actual
  actual=$(/usr/libexec/PlistBuddy -c "Print ${key}" "${plist}" 2>/dev/null) || {
    print -u2 "패키지 plist 필드 누락: ${plist} ${key}"
    exit 66
  }
  [[ "${actual}" == "${expected}" ]] || {
    print -u2 "패키지 plist 필드 불일치: ${plist} ${key}"
    exit 66
  }
}

helper_plist="${payload}/Library/LaunchDaemons/com.example.safeclam.helper.plist"
supervisor_plist="${payload}/Library/LaunchAgents/com.example.safeclam.supervisor.plist"
expect_plist_value "${helper_plist}" ":Label" "com.example.safeclam.helper"
expect_plist_value "${helper_plist}" ":ProgramArguments:0" \
  "/Library/Application Support/com.example.safeclam/bin/safeclam-helper"
expect_plist_value "${helper_plist}" ":UserName" "root"
expect_plist_value "${helper_plist}" ":MachServices:com.example.safeclam.helper" "true"
expect_plist_value "${helper_plist}" ":RunAtLoad" "true"
expect_plist_value "${helper_plist}" ":KeepAlive" "true"

expect_plist_value "${supervisor_plist}" ":Label" "com.example.safeclam.supervisor"
expect_plist_value "${supervisor_plist}" ":ProgramArguments:0" \
  "/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
expect_plist_value "${supervisor_plist}" ":MachServices:com.example.safeclam.supervisor" "true"
expect_plist_value "${supervisor_plist}" \
  ":MachServices:com.example.safeclam.supervisor.activity" "true"
expect_plist_value "${supervisor_plist}" ":RunAtLoad" "true"
expect_plist_value "${supervisor_plist}" ":KeepAlive" "true"
expect_plist_value "${supervisor_plist}" ":LimitLoadToSessionType" "Aqua"

expect_plist_value "${app_info}" ":CFBundleExecutable" "safeclam-menubar"
expect_plist_value "${app_info}" ":LSMinimumSystemVersion" "13.0"
expect_plist_value "${app_info}" ":LSUIElement" "true"
location_when_in_use=$(
  /usr/bin/plutil -extract NSLocationWhenInUseUsageDescription raw "${app_info}"
)
test -n "${location_when_in_use}" || {
  print -u2 "패키지 앱에 when-in-use 위치 권한 설명이 없음"
  exit 66
}

helper_requirement=$(
  /usr/bin/sed -n '1p' \
    "${payload}/Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
)
control_requirement=$(
  /usr/bin/sed -n '1p' \
    "${payload}/Library/Application Support/com.example.safeclam/supervisor/control.requirement"
)
activity_requirement=$(
  /usr/bin/sed -n '1p' \
    "${payload}/Library/Application Support/com.example.safeclam/supervisor/activity.requirement"
)

/usr/bin/csreq -r="${helper_requirement}" -t >/dev/null
/usr/bin/csreq -r="${control_requirement}" -t >/dev/null
/usr/bin/csreq -r="${activity_requirement}" -t >/dev/null
/usr/bin/codesign --verify --strict -R="${helper_requirement}" \
  "${payload}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
/usr/bin/codesign --verify --strict -R="${control_requirement}" \
  "${payload}/usr/local/bin/safeclam"
/usr/bin/codesign --verify --strict -R="${control_requirement}" \
  "${payload}/Applications/SafeClam.app"
/usr/bin/codesign --verify --strict -R="${activity_requirement}" \
  "${payload}/usr/local/bin/safeclam-hook"
/usr/bin/codesign --verify --strict -R="${activity_requirement}" \
  "${payload}/usr/local/bin/safeclam-activity"

rejects_requirement() {
  local requirement=$1
  local candidate=$2
  if /usr/bin/codesign --verify --strict -R="${requirement}" "${candidate}" \
    >/dev/null 2>&1
  then
    print -u2 "caller requirement가 비인가 바이너리를 허용함: ${candidate}"
    exit 66
  fi
}
rejects_requirement "${helper_requirement}" "${payload}/usr/local/bin/safeclam"
rejects_requirement "${control_requirement}" "${payload}/usr/local/bin/safeclam-hook"
rejects_requirement "${activity_requirement}" "${payload}/usr/local/bin/safeclam"

/usr/bin/plutil -lint \
  "${payload}/Library/LaunchDaemons/com.example.safeclam.helper.plist" \
  "${payload}/Library/LaunchAgents/com.example.safeclam.supervisor.plist" >/dev/null
for script in "${package_scripts}/preinstall" "${package_scripts}/postinstall"; do
  /bin/zsh -n "${script}"
done
if [[ "${SAFECLAM_SKIP_SOURCE_COMPARISON:-NO}" != "YES" ]]; then
  /usr/bin/cmp -s "${package_scripts}/preinstall" \
    "${project_root}/Packaging/pkg-scripts/preinstall" || {
    print -u2 "패키지 preinstall이 검증된 소스와 다름"
    exit 66
  }
  /usr/bin/cmp -s "${package_scripts}/postinstall" \
    "${project_root}/Packaging/pkg-scripts/postinstall" || {
    print -u2 "패키지 postinstall이 검증된 소스와 다름"
    exit 66
  }
  /usr/bin/cmp -s \
    "${payload}/Library/Application Support/com.example.safeclam/uninstall-safeclam" \
    "${project_root}/scripts/uninstall.sh" || {
    print -u2 "패키지 uninstall이 검증된 소스와 다름"
    exit 66
  }
fi

print "패키지 payload, caller requirement, 앱 권한 설명과 설치 스크립트 검증 통과"
