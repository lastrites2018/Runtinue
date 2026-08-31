#!/bin/zsh
set -euo pipefail

if [[ "${RUNTINUE_ALLOW_POWER_MUTATION:-NO}" != "YES" ]]; then
  print -u2 "실제 전원 변경 테스트입니다. RUNTINUE_ALLOW_POWER_MUTATION=YES를 명시해야 합니다"
  exit 77
fi

if [[ "$#" -gt 1 || \
  ( "$#" -eq 1 && "$1" != "--supervisor-crash" && "$1" != "--helper-crash" )
]]; then
  print -u2 "사용법: integration-test.sh [--supervisor-crash|--helper-crash]"
  exit 64
fi
scenario=${1:-normal}
script_dir=${0:A:h}
manifest=${RUNTINUE_EXPECTED_MANIFEST:-}
pkg=${RUNTINUE_EXPECTED_PKG:-}
expected_sha=${RUNTINUE_EXPECTED_SHA256:-}
[[ -f "${manifest}" && -f "${pkg}" && "${expected_sha}" =~ '^[0-9a-fA-F]{64}$' ]] || {
  print -u2 "고정 검증 대상이 필요합니다: RUNTINUE_EXPECTED_MANIFEST, RUNTINUE_EXPECTED_PKG, RUNTINUE_EXPECTED_SHA256"
  exit 64
}
actual_sha=$(/usr/bin/shasum -a 256 -- "${pkg}" | /usr/bin/awk '{print $1}')
[[ "${actual_sha:l}" == "${expected_sha:l}" ]] || {
  print -u2 "예상 패키지 SHA-256 불일치. 전원을 변경하지 않습니다"
  exit 65
}

cli=${RUNTINUE_CLI:-/usr/local/bin/runtinue}
[[ "${cli}" == /usr/local/bin/runtinue ]] || {
  print -u2 "통합 검증은 manifest로 확인한 설치 CLI만 사용합니다"
  exit 64
}
test -x "${cli}" || {
  print -u2 "설치된 runtinue CLI를 찾을 수 없음: ${cli}"
  exit 66
}
console_uid=$(/usr/bin/stat -f %u /dev/console)
[[ "${UID}" -eq "${console_uid}" && "${UID}" -ge 500 ]] || {
  print -u2 "전체 테스트를 sudo로 실행하지 말고 로그인한 사용자 Terminal에서 실행하세요"
  exit 77
}
# 이 단계는 읽기 전용이다. 인증 캐시가 없으면 암호를 요청하거나 테스트를 시작하지 않는다.
/usr/bin/sudo -n "${script_dir}/verify-installation.sh" "${manifest}" --pkg "${pkg}" --runtime || {
  print -u2 "설치 정합성 검사 실패. 필요한 경우 Terminal에서 sudo -v로 먼저 인증하세요"
  exit 77
}
preflight_status=$("${cli}" status --json)
preflight_mode=$(print -r -- "${preflight_status}" | /usr/bin/plutil -extract mode raw -)
preflight_phase=$(print -r -- "${preflight_status}" | /usr/bin/plutil -extract phase raw -)
[[ "${preflight_mode}" == none && ( "${preflight_phase}" == idle || "${preflight_phase}" == ended ) ]] || {
  print -u2 "기존 사용자 모드 또는 복구 작업이 있습니다. 종료한 뒤 다시 검증하세요"
  exit 70
}

sleep_state() {
  local output
  output=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null) || {
    print "unknown"
    return
  }
  if print -r -- "${output}" | /usr/bin/grep -q '"SleepDisabled" = No'; then
    print "normal"
  elif print -r -- "${output}" | /usr/bin/grep -q '"SleepDisabled" = Yes'; then
    print "disabled"
  else
    print "unknown"
  fi
}

cleanup() {
  "${cli}" desk disable >/dev/null 2>&1 || true
  "${cli}" adaptive disable >/dev/null 2>&1 || true
  "${cli}" stop >/dev/null 2>&1 || true
  for _ in {1..100}; do
    [[ "$(sleep_state)" == "normal" ]] && return
    /bin/sleep 1
  done
  print -u2 "정리 뒤 정상 수면을 확인하지 못했습니다. helper와 진단 상태를 즉시 확인하세요"
}
[[ "$(sleep_state)" == "normal" ]] || {
  print -u2 "테스트 시작 전 SleepDisabled가 정상 상태가 아님"
  exit 70
}

print "통합 검증 대상 SHA-256: ${actual_sha}"
print "시나리오: ${scenario}, 시작: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
/bin/launchctl print system/io.github.lastrites2018.runtinue.helper >/dev/null
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${cli}" desk enable --max 2m --closed-lid
for _ in {1..20}; do
  [[ "$(sleep_state)" == "disabled" ]] && break
  /bin/sleep 1
done
[[ "$(sleep_state)" == "disabled" ]] || {
  print -u2 "유한 privileged lease 활성화를 확인하지 못함"
  exit 1
}
"${cli}" verify-helper-boundary

if [[ "${scenario}" == "--supervisor-crash" ]]; then
  /bin/launchctl kill SIGKILL "gui/${UID}/io.github.lastrites2018.runtinue.supervisor"
  for _ in {1..100}; do
    [[ "$(sleep_state)" == "normal" ]] && break
    /bin/sleep 1
  done
elif [[ "${scenario}" == "--helper-crash" ]]; then
  /usr/bin/sudo -n /bin/launchctl kill SIGKILL system/io.github.lastrites2018.runtinue.helper
  for _ in {1..100}; do
    [[ "$(sleep_state)" == "normal" ]] && break
    /bin/sleep 1
  done
  /bin/launchctl print system/io.github.lastrites2018.runtinue.helper >/dev/null
else
  "${cli}" desk disable
fi

[[ "$(sleep_state)" == "normal" ]] || {
  print -u2 "테스트 종료 뒤 정상 수면 복구 실패"
  exit 1
}
trap - EXIT INT TERM
print "실제 Mac 유한 lease와 정상 수면 복구 검증 통과"
print "종료: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ), SleepDisabled=No"
