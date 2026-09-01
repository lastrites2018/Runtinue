#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
test_root=$(/usr/bin/mktemp -d /tmp/runtinue-install-preflight.XXXXXX)
trap '/bin/rm -rf -- "${test_root}"' EXIT
fixture_root="${test_root}/root"
mock_root="${test_root}/mocks"
preflight="${test_root}/preinstall"
command_log="${test_root}/commands"
mkdir -p "${mock_root}" "${fixture_root}/Applications" "${fixture_root}/usr/local/bin" \
  "${fixture_root}/Library/Application Support" "${fixture_root}/Library/LaunchAgents" \
  "${fixture_root}/Library/LaunchDaemons"

# 실제 설치 스크립트의 경로와 시스템 명령을 테스트 사본에서만 격리한다.
# 제품에는 임의 root 경로나 전원 설정 우회용 환경 변수를 추가하지 않는다.
/usr/bin/sed \
  -e "s|/Applications/|${fixture_root}/Applications/|g" \
  -e "s|/Library/|${fixture_root}/Library/|g" \
  -e "s|/usr/local/bin/|${fixture_root}/usr/local/bin/|g" \
  -e "s|/usr/bin/stat|${mock_root}/stat|g" \
  -e "s|/usr/bin/uname|${mock_root}/uname|g" \
  -e "s|/usr/sbin/ioreg|${mock_root}/ioreg|g" \
  -e "s|/bin/launchctl|${mock_root}/launchctl|g" \
  -e "s|/bin/sleep|${mock_root}/sleep|g" \
  "${project_root}/Packaging/pkg-scripts/preinstall" > "${preflight}"
printf '%s\n' '#!/bin/zsh' 'print 501' > "${mock_root}/stat"
printf '%s\n' '#!/bin/zsh' 'print -r -- "${RUNTINUE_TEST_ARCH:-arm64}"' > "${mock_root}/uname"
printf '%s\n' '#!/bin/zsh' \
  'print -r -- "\"SleepDisabled\" = ${RUNTINUE_TEST_SLEEP_STATE:-No}"' > "${mock_root}/ioreg"
printf '%s\n' '#!/bin/zsh' \
  'print -r -- "$*" >> "${RUNTINUE_TEST_COMMAND_LOG}"' \
  '[[ "$1" == print ]] || exit 90' \
  '[[ "$2" == system/com.example.safeclam.helper && "${RUNTINUE_TEST_HELPER_LOADED:-NO}" == YES ]] && exit 0' \
  '[[ "$2" == gui/501/com.example.safeclam.supervisor && "${RUNTINUE_TEST_SUPERVISOR_LOADED:-NO}" == YES ]] && exit 0' \
  'exit 113' > "${mock_root}/launchctl"
printf '%s\n' '#!/bin/zsh' 'exit 97' > "${mock_root}/sleep"
chmod +x "${mock_root}/stat" "${mock_root}/uname" "${mock_root}/ioreg" "${mock_root}/launchctl" "${mock_root}/sleep"

passed=0
expect_preflight() {
  local expected=$1
  local label=$2
  : > "${command_log}"
  set +e
  RUNTINUE_TEST_COMMAND_LOG="${command_log}" /bin/zsh "${preflight}" \
    > "${test_root}/result" 2>&1
  local actual=$?
  set -e
  if [[ "${actual}" -ne "${expected}" ]]; then
    print -u2 "설치 전 검사 실패: ${label}, 예상 ${expected}, 실제 ${actual}"
    /usr/bin/sed -n '1,20p' "${test_root}/result" >&2
    exit 1
  fi
  if /usr/bin/grep -Eq '^(asuser|bootstrap|bootout|enable|disable|kickstart)' "${command_log}"; then
    print -u2 "설치 전 거부 과정에서 서비스를 변경함: ${label}"
    exit 1
  fi
  passed=$((passed + 1))
}

expect_preflight 0 "새 설치와 정상 수면"
RUNTINUE_TEST_ARCH=x86_64 expect_preflight 65 "Intel과 Rosetta 설치는 서비스 변경 전 차단"
RUNTINUE_TEST_ARCH=unknown expect_preflight 65 "확인 불가능한 아키텍처 차단"
for legacy_path in \
  /Applications/SafeClam.app \
  /usr/local/bin/safeclam \
  /usr/local/bin/safeclam-hook \
  /usr/local/bin/safeclam-activity \
  "/Library/Application Support/com.example.safeclam" \
  /Library/LaunchDaemons/com.example.safeclam.helper.plist \
  /Library/LaunchAgents/com.example.safeclam.supervisor.plist; do
  legacy_file="${fixture_root}${legacy_path}"
  /usr/bin/touch "${legacy_file}"
  expect_preflight 78 "이전 설치 경로: ${legacy_path}"
  /bin/rm -f -- "${legacy_file}"
done
/bin/ln -s missing "${fixture_root}/Applications/SafeClam.app"
expect_preflight 78 "이전 앱의 끊어진 심볼릭 링크"
/bin/rm -f -- "${fixture_root}/Applications/SafeClam.app"

RUNTINUE_TEST_HELPER_LOADED=YES expect_preflight 78 "파일 없이 남은 이전 Helper"
RUNTINUE_TEST_SUPERVISOR_LOADED=YES expect_preflight 78 "파일 없이 남은 이전 Supervisor"
RUNTINUE_TEST_SLEEP_STATE=Yes expect_preflight 70 "소유자가 불명확한 수면 억제"
RUNTINUE_TEST_SLEEP_STATE=Unknown expect_preflight 70 "확인 불가능한 전원 상태"

mkdir -p "${fixture_root}/Applications/Runtinue.app" "${test_root}/user/Library/Application Support/SafeClam"
printf '%s\n' 'preserve legacy user history' \
  > "${test_root}/user/Library/Application Support/SafeClam/history.jsonl"
expect_preflight 0 "새 이름의 앱과 이전 사용자 기록 보존"
/usr/bin/grep -qx 'preserve legacy user history' \
  "${test_root}/user/Library/Application Support/SafeClam/history.jsonl"
print "설치 전 이름 전환과 전원 보호 검사 ${passed}개 통과"
