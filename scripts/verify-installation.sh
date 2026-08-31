#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
manifest=${1:-}
shift || true
pkg=""
runtime=NO
rollback=NO
install_root=${RUNTINUE_INSTALL_ROOT:-/}

usage() {
  print -u2 "사용법: verify-installation.sh <manifest.json> [--pkg <Runtinue.pkg>] [--runtime] [--rollback]"
  exit 64
}

fail() {
  local code=${2:-66}
  print -u2 -- "$1"
  exit "${code}"
}

[[ -n "${manifest}" ]] || usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg)
      [[ $# -ge 2 ]] || usage
      pkg=$2
      shift 2
      ;;
    --runtime)
      runtime=YES
      shift
      ;;
    --rollback)
      rollback=YES
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -f "${manifest}" ]] || fail "manifest를 찾을 수 없음: ${manifest}"
valid_json() {
  /usr/bin/plutil -convert xml1 -o /dev/null -- "$1" >/dev/null 2>&1
}
valid_json "${manifest}" || fail "manifest JSON이 올바르지 않음" 65

manifest_value() {
  /usr/bin/plutil -extract "$1" raw "${manifest}" 2>/dev/null
}

valid_sha256() {
  [[ "$1" =~ '^[0-9a-fA-F]{64}$' ]]
}

sha256() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

schema=$(manifest_value schemaVersion) || fail "manifest schemaVersion 누락" 65
[[ "${schema}" == 1 ]] || fail "지원하지 않는 manifest schemaVersion: ${schema}" 65
identifier=$(manifest_value package.identifier) || fail "manifest package.identifier 누락" 65
[[ "${identifier}" == "io.github.lastrites2018.runtinue.pkg" ]] || fail "manifest package identifier 불일치" 65
expected_version=$(manifest_value package.version) || fail "manifest package.version 누락" 65
[[ "${expected_version}" =~ '^[0-9]+([.][0-9]+){1,3}$' ]] || fail "manifest package.version 형식 오류" 65
package_hash=$(manifest_value package.sha256) || fail "manifest package.sha256 누락" 65
valid_sha256 "${package_hash}" || fail "manifest package.sha256 형식 오류" 65
build_id=$(manifest_value buildID) || fail "manifest buildID 누락" 65
valid_sha256 "${build_id}" || fail "manifest buildID 형식 오류" 65

if [[ "${install_root}" != /* ]]; then
  fail "RUNTINUE_INSTALL_ROOT는 절대 경로여야 함" 64
fi
if [[ "${install_root}" != "/" && "${RUNTINUE_INSTALL_FIXTURE:-NO}" != YES ]]; then
  fail "실제 설치가 아닌 root는 RUNTINUE_INSTALL_FIXTURE=YES에서만 허용" 64
fi

installed_path() {
  local absolute_path=$1
  if [[ "${install_root}" == "/" ]]; then
    print -r -- "${absolute_path}"
  else
    print -r -- "${install_root}${absolute_path}"
  fi
}

verify_file() {
  local key=$1
  local expected_path=$2
  local actual_path expected_hash actual_hash
  actual_path=$(manifest_value "${key}.installedPath") || fail "manifest 설치 경로 누락: ${key}" 65
  [[ "${actual_path}" == "${expected_path}" ]] || fail "manifest 설치 경로 불일치: ${key}" 65
  expected_hash=$(manifest_value "${key}.sha256") || fail "manifest hash 누락: ${key}" 65
  valid_sha256 "${expected_hash}" || fail "manifest hash 형식 오류: ${key}" 65
  actual_path=$(installed_path "${actual_path}")
  [[ -f "${actual_path}" && ! -L "${actual_path}" ]] || fail "설치 파일 누락 또는 symlink: ${expected_path}" 66
  [[ -r "${actual_path}" ]] || fail "설치 파일 읽기 권한 부족. 관리자 권한으로 읽기 전용 검사를 실행하세요: ${expected_path}" 77
  if [[ "${install_root}" == "/" ]]; then
    local file_owner file_mode
    file_owner=$(/usr/bin/stat -f %u "${actual_path}")
    file_mode=$(/usr/bin/stat -f %Lp "${actual_path}")
    [[ "${file_owner}" == 0 ]] && (( (8#${file_mode} & 8#022) == 0 )) || \
      fail "설치 파일 소유자 또는 쓰기 권한 오류: ${expected_path}" 65
  fi
  actual_hash=$(sha256 "${actual_path}")
  [[ "${actual_hash:l}" == "${expected_hash:l}" ]] || fail "설치 파일 변조 또는 다른 패키지: ${expected_path}" 65
}

verify_file artifacts.runtinue "/usr/local/bin/runtinue"
verify_file artifacts.runtinueHook "/usr/local/bin/runtinue-hook"
verify_file artifacts.runtinueActivity "/usr/local/bin/runtinue-activity"
verify_file artifacts.runtinueHelper \
  "/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-helper"
verify_file artifacts.runtinueSupervisor \
  "/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor"
verify_file artifacts.runtinueMenubar \
  "/Applications/Runtinue.app/Contents/MacOS/runtinue-menubar"
verify_file artifacts.runtinueAppInfo \
  "/Applications/Runtinue.app/Contents/Info.plist"
verify_file artifacts.runtinueAppCodeResources \
  "/Applications/Runtinue.app/Contents/_CodeSignature/CodeResources"
verify_file artifacts.runtinueMenuIcon \
  "/Applications/Runtinue.app/Contents/Resources/RuntinueTemplate.png"
verify_file artifacts.runtinueAppIcon \
  "/Applications/Runtinue.app/Contents/Resources/Runtinue.icns"
verify_file artifacts.helperPlist \
  "/Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist"
verify_file artifacts.supervisorPlist \
  "/Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist"
verify_file artifacts.uninstallScript \
  "/Library/Application Support/io.github.lastrites2018.runtinue/uninstall-runtinue"
verify_file requirements.helperSupervisor \
  "/Library/Application Support/io.github.lastrites2018.runtinue/helper/supervisor.requirement"
verify_file requirements.control \
  "/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/control.requirement"
verify_file requirements.activity \
  "/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/activity.requirement"

supervisor_hash=$(manifest_value artifacts.runtinueSupervisor.sha256) || fail "Supervisor hash 누락" 65
[[ "${supervisor_hash:l}" == "${build_id:l}" ]] || fail "manifest buildID와 Supervisor hash 불일치" 65

package_check=not-run
if [[ -n "${pkg}" ]]; then
  [[ -f "${pkg}" ]] || fail "검증할 패키지를 찾을 수 없음: ${pkg}"
  if [[ "${rollback}" == YES ]]; then
    "${script_dir}/release-manifest.sh" verify "${pkg}" "${manifest}" --rollback >/dev/null
  else
    "${script_dir}/release-manifest.sh" verify "${pkg}" "${manifest}" >/dev/null
  fi
  package_check=passed
fi

receipt_check=not-run
if [[ "${install_root}" == "/" ]]; then
  receipt_info=$(/usr/sbin/pkgutil --pkg-info io.github.lastrites2018.runtinue.pkg 2>/dev/null) || \
    fail "설치 영수증을 찾을 수 없음" 66
  receipt_version=$(print -r -- "${receipt_info}" | /usr/bin/sed -n 's/^version: //p' | /usr/bin/sed -n '1p')
  [[ "${receipt_version}" == "${expected_version}" ]] || fail "설치 영수증 version 불일치" 65
  receipt_check=passed
else
  receipt_check=not-run-fixture
fi

if [[ "${runtime}" == YES ]]; then
  [[ "${install_root}" == "/" ]] || fail "fixture root에서는 runtime 검증을 실행하지 않음" 64
  console_uid=$(/usr/bin/stat -f %u /dev/console 2>/dev/null) || fail "console UID를 확인할 수 없음" 66
  [[ "${console_uid}" =~ '^[0-9]+$' ]] || fail "console UID 형식 오류" 66
  [[ "${console_uid}" -ge 500 ]] || fail "로그인한 사용자 세션이 없음" 67
  /bin/launchctl print "gui/${console_uid}/io.github.lastrites2018.runtinue.supervisor" >/dev/null 2>&1 || \
    fail "Supervisor launchd 상태 검증 실패" 67
  /bin/launchctl print system/io.github.lastrites2018.runtinue.helper >/dev/null 2>&1 || \
    fail "Helper launchd 상태 검증 실패" 67
  # root 설치 검사와 사용자 XPC의 인증 주체를 섞지 않는다.
  console_cli() {
    if [[ "${EUID}" -eq 0 ]]; then
      /bin/launchctl asuser "${console_uid}" \
        /usr/bin/sudo -n -u "#${console_uid}" /usr/local/bin/runtinue "$@"
    elif [[ "${EUID}" -eq "${console_uid}" ]]; then
      /usr/local/bin/runtinue "$@"
    else
      fail "runtime 검사는 console 사용자 또는 root로 실행해야 함" 77
    fi
  }
  runtime_identity=not-observable-legacy
  if status_json=$(console_cli status --json 2>/dev/null); then
    live_build=$(print -r -- "${status_json}" | /usr/bin/plutil -extract observation.buildID raw - 2>/dev/null) || \
      fail "실행 중인 Supervisor가 buildID를 제공하지 않음" 67
    [[ "${live_build:l}" == "${build_id:l}" ]] || \
      fail "실행 중인 Supervisor와 manifest buildID 불일치" 67
    runtime_identity=matched
  elif [[ "${rollback}" == YES ]] && console_cli status >/dev/null 2>&1; then
    print "이전 버전은 runtime buildID를 제공하지 않음. 디스크 정합성과 XPC 연결만 확인함"
  else
    fail "Supervisor CLI status runtime 검증 실패" 67
  fi
  runtime_check=passed
else
  runtime_check=not-run
fi

print "설치 정적 검증 통과: manifest=${manifest} package=${package_check} receipt=${receipt_check}"
print "runtime 검증 상태: ${runtime_check}"
[[ "${runtime}" != YES ]] || print "runtime buildID 검증: ${runtime_identity}"
print "전원, 핫스팟과 실제 통근 여정 검증: not-run"
