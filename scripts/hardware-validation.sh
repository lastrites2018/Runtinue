#!/bin/zsh
set -euo pipefail

# 이 도구는 기록의 대상과 완결성만 검사한다. 실기기 시험을 실행하거나 결과를 추정하지 않는다.
required_cases=(
  cleanInstall acquireRelease helperBoundary supervisorCrash helperCrash
  closedLid15Minutes acToBattery hotspotHandoff hotspotAlreadyConnected usbTethering
  batteryFloor thermalRelease sensorUnavailable reboot upgrade uninstall
)
fail() { print -u2 -- "$1"; exit "${2:-65}"; }
value() { /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null; }
action=${1:-}
if [[ "${action}" == cases && $# -eq 1 ]]; then
  print -l -- "${required_cases[@]}"
  exit 0
fi
[[ $# -eq 3 && ( "${action}" == create || "${action}" == verify ) ]] || \
  fail "사용법: hardware-validation.sh create|verify <manifest.json> <record.json>" 64
manifest=$2
record=$3
[[ -f "${manifest}" ]] || fail "manifest 파일이 필요합니다" 66
package_sha=$(value "${manifest}" package.sha256) || fail "패키지 SHA-256이 없습니다"
source_commit=$(value "${manifest}" source.commitSHA) || fail "소스 commit이 없는 후보는 기록할 수 없습니다"
source_state=$(value "${manifest}" source.workingTreeState) || fail "소스 작업 트리 상태가 없습니다"
signature_status=$(value "${manifest}" package.signatureStatus) || fail "서명 상태가 없습니다"
[[ "${package_sha}" =~ '^[0-9a-f]{64}$' && "${source_commit}" =~ '^[0-9a-f]{40}$' ]] || \
  fail "패키지 또는 소스 식별자 형식 오류"
[[ "${source_state}" == clean || "${source_state}" == dirty ]] || fail "작업 트리 상태 형식 오류"
case "${signature_status}" in
  unsigned-development|signed-notarized|signed-installer-not-notarized) ;;
  *) fail "서명 상태 형식 오류" ;;
esac

if [[ "${action}" == create ]]; then
  [[ ! -e "${record}" && ! -L "${record}" ]] || fail "기존 실기기 기록을 덮어쓰지 않습니다" 73
  hardware_model=$(/usr/sbin/sysctl -n hw.model) || fail "Mac 모델을 읽지 못했습니다" 69
  hardware_macos=$(/usr/bin/sw_vers -productVersion) || fail "macOS 버전을 읽지 못했습니다" 69
  /bin/mkdir -p "${record:h}"
  record_tmp=$(/usr/bin/mktemp "${record}.tmp.XXXXXX")
  trap '/bin/rm -f -- "${record_tmp}"' EXIT
  /usr/bin/plutil -create xml1 "${record_tmp}"
  /usr/bin/plutil -insert schemaVersion -integer 1 "${record_tmp}"
  /usr/bin/plutil -insert packageSHA256 -string "${package_sha}" "${record_tmp}"
  /usr/bin/plutil -insert sourceCommit -string "${source_commit}" "${record_tmp}"
  /usr/bin/plutil -insert sourceWorkingTreeState -string "${source_state}" "${record_tmp}"
  /usr/bin/plutil -insert signatureStatus -string "${signature_status}" "${record_tmp}"
  /usr/bin/plutil -insert hardware -dictionary "${record_tmp}"
  /usr/bin/plutil -insert hardware.model -string "${hardware_model}" "${record_tmp}"
  /usr/bin/plutil -insert hardware.macosVersion -string "${hardware_macos}" "${record_tmp}"
  /usr/bin/plutil -insert operatorConfirmed -bool NO "${record_tmp}"
  /usr/bin/plutil -insert tests -dictionary "${record_tmp}"
  for test_case in "${required_cases[@]}"; do
    /usr/bin/plutil -insert "tests.${test_case}" -dictionary "${record_tmp}"
    /usr/bin/plutil -insert "tests.${test_case}.status" -string notRun "${record_tmp}"
    for field in startedAt endedAt startSleepDisabled endSleepDisabled result; do
      /usr/bin/plutil -insert "tests.${test_case}.${field}" -string "" "${record_tmp}"
    done
  done
  /usr/bin/plutil -convert json -r "${record_tmp}"
  /bin/mv -n -- "${record_tmp}" "${record}"
  [[ ! -e "${record_tmp}" ]] || fail "동시에 생성된 기존 실기기 기록을 보존했습니다" 73
  print "미실행 상태의 실기기 기록 생성: ${record}"
  exit 0
fi

[[ -f "${record}" ]] || fail "실기기 검증 기록이 없어 배포를 보류합니다" 78
[[ "$(value "${record}" schemaVersion)" == 1 && \
  "$(value "${record}" packageSHA256)" == "${package_sha}" && \
  "$(value "${record}" sourceCommit)" == "${source_commit}" && \
  "$(value "${record}" sourceWorkingTreeState)" == "${source_state}" && \
  "$(value "${record}" signatureStatus)" == "${signature_status}" ]] || \
  fail "실기기 기록이 현재 후보 패키지와 일치하지 않습니다"
[[ "$(value "${record}" operatorConfirmed)" == true ]] || fail "실험자의 실제 수행 확인이 필요합니다" 78
model=$(value "${record}" hardware.model)
macos_version=$(value "${record}" hardware.macosVersion)
[[ -n "${model}" && "${macos_version}" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?$' ]] || fail "실기기 모델과 macOS 버전이 필요합니다"
now_epoch=$(/bin/date +%s)
for test_case in "${required_cases[@]}"; do
  [[ "$(value "${record}" "tests.${test_case}.status")" == passed && \
    "$(value "${record}" "tests.${test_case}.startSleepDisabled")" == No && \
    "$(value "${record}" "tests.${test_case}.endSleepDisabled")" == No && \
    -n "$(value "${record}" "tests.${test_case}.result")" ]] || \
    fail "미실행, 실패 또는 정상 수면 복구 미확인: ${test_case}" 78
  started=$(value "${record}" "tests.${test_case}.startedAt")
  ended=$(value "${record}" "tests.${test_case}.endedAt")
  for timestamp in "${started}" "${ended}"; do
    [[ "${timestamp}" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] || \
      fail "시험 시간은 UTC ISO 8601 형식이어야 합니다: ${test_case}"
  done
  start_epoch=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${started}" +%s 2>/dev/null) || fail "시험 시작 시간 오류: ${test_case}"
  end_epoch=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${ended}" +%s 2>/dev/null) || fail "시험 종료 시간 오류: ${test_case}"
  (( start_epoch <= end_epoch && end_epoch <= now_epoch )) || fail "시험 시간 순서 오류: ${test_case}"
  if [[ "${test_case}" == closedLid15Minutes ]]; then
    (( end_epoch - start_epoch >= 900 )) || fail "덮개 닫힘 시험 기록은 최소 15분이어야 합니다" 78
  fi
done
print "실기기 기록의 후보 일치와 필수 항목 확인 통과. 실제 수행 사실은 실험자의 확인에 의존합니다"
