#!/bin/zsh
set -euo pipefail

if [[ "${RUNTINUE_ALLOW_POWER_MUTATION:-NO}" != "YES" ]]; then
  print -u2 "실제 전원 변경 테스트입니다. RUNTINUE_ALLOW_POWER_MUTATION=YES를 명시해야 합니다"
  exit 77
fi

if [[ "$#" -gt 1 || \
  ( "$#" -eq 1 && "$1" != "--supervisor-crash" && "$1" != "--helper-crash" && \
    "$1" != "--timed-assertion-timeout" )
]]; then
  print -u2 "사용법: integration-test.sh [--supervisor-crash|--helper-crash|--timed-assertion-timeout]"
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

desk_assertion_active() {
  /usr/bin/pmset -g assertions 2>/dev/null | \
    /usr/bin/grep -Fq 'Runtinue desk mode'
}

supervisor_stopped=NO
cleanup() {
  if [[ "${supervisor_stopped}" == YES ]]; then
    /bin/launchctl kill SIGCONT "gui/${UID}/io.github.lastrites2018.runtinue.supervisor" \
      >/dev/null 2>&1 || true
    supervisor_stopped=NO
  fi
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
if [[ "${scenario}" == "--timed-assertion-timeout" ]] && desk_assertion_active; then
  print -u2 "테스트 시작 전 기존 Runtinue desk assertion이 남아 있습니다"
  exit 70
fi

print "통합 검증 대상 SHA-256: ${actual_sha}"
print "시나리오: ${scenario}, 시작: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
/bin/launchctl print system/io.github.lastrites2018.runtinue.helper >/dev/null
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${scenario}" == "--timed-assertion-timeout" ]]; then
  # 덮개가 열린 경로의 process-owned assertion이 Supervisor 정지 중에도 유한한지
  # 확인한다. 현재 구현이 운영체제 timeout을 설정하지 않으면 이 시험은 실패해야 한다.
  "${cli}" desk enable --max 15s
  for _ in {1..20}; do
    desk_assertion_active && break
    /bin/sleep 1
  done
  desk_assertion_active || {
    print -u2 "Runtinue desk assertion 활성화를 확인하지 못함"
    exit 1
  }
  [[ "$(sleep_state)" == "normal" ]] || {
    print -u2 "열린 덮개 assertion이 시스템 SleepDisabled를 변경했습니다"
    exit 1
  }
  /bin/launchctl kill SIGSTOP "gui/${UID}/io.github.lastrites2018.runtinue.supervisor"
  supervisor_stopped=YES
  for _ in {1..45}; do
    desk_assertion_active || break
    /bin/sleep 1
  done
  desk_assertion_active && {
    print -u2 "Supervisor 정지 중 유한 assertion이 운영체제 기한 안에 만료되지 않았습니다"
    exit 1
  }
  /bin/launchctl kill SIGCONT "gui/${UID}/io.github.lastrites2018.runtinue.supervisor"
  supervisor_stopped=NO
  for _ in {1..30}; do
    timed_status=$("${cli}" status --json 2>/dev/null) || {
      /bin/sleep 1
      continue
    }
    timed_phase=$(print -r -- "${timed_status}" | /usr/bin/plutil -extract phase raw - 2>/dev/null) || {
      /bin/sleep 1
      continue
    }
    [[ "${timed_phase}" == idle || "${timed_phase}" == ended ]] && break
    /bin/sleep 1
  done
  [[ "${timed_phase:-unknown}" == idle || "${timed_phase:-unknown}" == ended ]] || {
    print -u2 "Supervisor 재개 뒤 유한 session이 종료 상태로 정리되지 않았습니다"
    exit 1
  }
  [[ "$(sleep_state)" == "normal" ]] || {
    print -u2 "유한 assertion 시험 뒤 정상 수면 상태가 아닙니다"
    exit 1
  }
  trap - EXIT HUP INT TERM
  print "Supervisor 정지 중 유한 open-lid assertion 만료 검증 통과"
  print "종료: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ), SleepDisabled=No"
  exit 0
fi

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
trap - EXIT HUP INT TERM
print "실제 Mac 유한 lease와 정상 수면 복구 검증 통과"
print "종료: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ), SleepDisabled=No"
