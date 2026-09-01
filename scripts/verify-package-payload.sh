#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
pkg=${1:-}
test -n "${pkg}" && test -f "${pkg}" || {
  print -u2 "사용법: verify-package-payload.sh <Runtinue.pkg>"
  exit 64
}

work_root=$(/usr/bin/mktemp -d /tmp/runtinue-package-payload.XXXXXX)
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
  "${payload}/usr/local/bin/runtinue"
  "${payload}/usr/local/bin/runtinue-hook"
  "${payload}/usr/local/bin/runtinue-activity"
  "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-helper"
  "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor"
  "${payload}/Applications/Runtinue.app"
  "${payload}/Applications/Runtinue.app/Contents/MacOS/runtinue-menubar"
  "${payload}/Applications/Runtinue.app/Contents/Resources/RuntinueTemplate.png"
  "${payload}/Applications/Runtinue.app/Contents/Resources/Runtinue.icns"
  "${payload}/Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist"
  "${payload}/Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist"
)
for path in "${required_paths[@]}"; do
  test -e "${path}" || {
    print -u2 "패키지 payload 누락: ${path}"
    exit 66
  }
done

require_arm64() {
  local artifact_path=$1
  local architectures
  architectures=$(/usr/bin/lipo -archs "${artifact_path}" 2>/dev/null) || {
    print -u2 "Mach-O 실행 파일을 확인할 수 없음: ${artifact_path}"
    exit 65
  }
  [[ "${architectures}" == arm64 ]] || {
    print -u2 "Apple Silicon 전용 payload가 아님: ${artifact_path} (${architectures})"
    exit 65
  }
}
for artifact_path in \
  "${payload}/usr/local/bin/runtinue" "${payload}/usr/local/bin/runtinue-hook" \
  "${payload}/usr/local/bin/runtinue-activity" \
  "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-helper" \
  "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor" \
  "${payload}/Applications/Runtinue.app/Contents/MacOS/runtinue-menubar"; do
  require_arm64 "${artifact_path}"
done
# 추가된 라이브러리나 실행 파일도 아키텍처 검사에서 빠지지 않도록 전부 확인한다.
for artifact_path in "${payload}"/**/*(.DN); do
  if /usr/bin/file -b "${artifact_path}" | /usr/bin/grep -q '^Mach-O'; then
    require_arm64 "${artifact_path}"
  fi
done

app_info="${payload}/Applications/Runtinue.app/Contents/Info.plist"
package_info="${payload:h}/PackageInfo"
package_version=$(/usr/bin/sed -n 's/^<pkg-info[^>]* version="\([^"]*\)".*/\1/p' "${package_info}")
app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${app_info}")
[[ -n "${package_version}" && "${app_version}" == "${package_version}" ]] || {
  print -u2 "앱과 패키지 버전이 일치하지 않음"
  exit 65
}
source_commit=$(/usr/bin/plutil -extract RuntinueSourceCommit raw "${app_info}" 2>/dev/null || true)
source_dirty=$(/usr/bin/plutil -extract RuntinueSourceDirty raw "${app_info}" 2>/dev/null || true)
if [[ -n "${source_commit}" || -n "${source_dirty}" || "${RUNTINUE_SKIP_SOURCE_COMPARISON:-NO}" != YES ]]; then
  [[ "${source_commit}" =~ '^[0-9a-f]{40}$' && ( "${source_dirty}" == true || "${source_dirty}" == false ) ]] || {
    print -u2 "앱의 소스 commit 또는 작업 트리 상태가 올바르지 않음"
    exit 65
  }
fi

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
[[ "${app_identifier}" == "io.github.lastrites2018.runtinue.app" ]] || {
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

helper_plist="${payload}/Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist"
supervisor_plist="${payload}/Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist"
expect_plist_value "${helper_plist}" ":Label" "io.github.lastrites2018.runtinue.helper"
expect_plist_value "${helper_plist}" ":ProgramArguments:0" \
  "/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-helper"
expect_plist_value "${helper_plist}" ":UserName" "root"
expect_plist_value "${helper_plist}" ":MachServices:io.github.lastrites2018.runtinue.helper" "true"
expect_plist_value "${helper_plist}" ":RunAtLoad" "true"
expect_plist_value "${helper_plist}" ":KeepAlive" "true"

expect_plist_value "${supervisor_plist}" ":Label" "io.github.lastrites2018.runtinue.supervisor"
expect_plist_value "${supervisor_plist}" ":ProgramArguments:0" \
  "/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor"
expect_plist_value "${supervisor_plist}" ":MachServices:io.github.lastrites2018.runtinue.supervisor" "true"
expect_plist_value "${supervisor_plist}" \
  ":MachServices:io.github.lastrites2018.runtinue.supervisor.activity" "true"
expect_plist_value "${supervisor_plist}" ":RunAtLoad" "true"
expect_plist_value "${supervisor_plist}" ":KeepAlive" "true"
expect_plist_value "${supervisor_plist}" ":LimitLoadToSessionType" "Aqua"

expect_plist_value "${app_info}" ":CFBundleExecutable" "runtinue-menubar"
expect_plist_value "${app_info}" ":CFBundleName" "Runtinue"
expect_plist_value "${app_info}" ":CFBundleDisplayName" "Runtinue"
expect_plist_value "${app_info}" ":CFBundleIconFile" "Runtinue"
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
    "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/helper/supervisor.requirement"
)
control_requirement=$(
  /usr/bin/sed -n '1p' \
    "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/control.requirement"
)
activity_requirement=$(
  /usr/bin/sed -n '1p' \
    "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/activity.requirement"
)

/usr/bin/csreq -r="${helper_requirement}" -t >/dev/null
/usr/bin/csreq -r="${control_requirement}" -t >/dev/null
/usr/bin/csreq -r="${activity_requirement}" -t >/dev/null
/usr/bin/codesign --verify --strict -R="${helper_requirement}" \
  "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor"
/usr/bin/codesign --verify --strict -R="${control_requirement}" \
  "${payload}/usr/local/bin/runtinue"
/usr/bin/codesign --verify --strict -R="${control_requirement}" \
  "${payload}/Applications/Runtinue.app"
/usr/bin/codesign --verify --strict -R="${activity_requirement}" \
  "${payload}/usr/local/bin/runtinue-hook"
/usr/bin/codesign --verify --strict -R="${activity_requirement}" \
  "${payload}/usr/local/bin/runtinue-activity"

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
rejects_requirement "${helper_requirement}" "${payload}/usr/local/bin/runtinue"
rejects_requirement "${control_requirement}" "${payload}/usr/local/bin/runtinue-hook"
rejects_requirement "${activity_requirement}" "${payload}/usr/local/bin/runtinue"

/usr/bin/plutil -lint \
  "${payload}/Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist" \
  "${payload}/Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist" >/dev/null
for script in "${package_scripts}/preinstall" "${package_scripts}/postinstall"; do
  /bin/zsh -n "${script}"
done
if [[ "${RUNTINUE_SKIP_SOURCE_COMPARISON:-NO}" != "YES" ]]; then
  [[ "${app_version}" == "$(/bin/zsh "${script_dir}/version.sh")" ]] || {
    print -u2 "패키지 버전이 현재 VERSION 파일과 다름"
    exit 65
  }
  /usr/bin/cmp -s "${payload}/Applications/Runtinue.app/Contents/Resources/RuntinueTemplate.png" \
    "${project_root}/Sources/RuntinueMenuBar/Resources/RuntinueTemplate.png" || {
    print -u2 "패키지 메뉴바 아이콘이 검증된 소스와 다름"
    exit 66
  }
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
    "${payload}/Library/Application Support/io.github.lastrites2018.runtinue/uninstall-runtinue" \
    "${project_root}/scripts/uninstall.sh" || {
    print -u2 "패키지 uninstall이 검증된 소스와 다름"
    exit 66
  }
fi

print "패키지 payload, arm64, 버전, 소스 식별자, caller requirement와 설치 스크립트 검증 통과"
