#!/bin/zsh
set -euo pipefail

hardware_script_dir=${0:A:h}

# 실기기 검증은 후보 패키지와 실행 경계를 고정하고, 안전하게 다시 확인할 수 있는
# 최소 증거만 기록한다. 자유 형식 로그나 개인 경로는 기록하지 않는다.
required_cases=(
  cleanInstall acquireRelease helperBoundary supervisorCrash helperCrash
  timedAssertionExpiry closedLid15Minutes acToBattery hotspotHandoff
  hotspotAlreadyConnected usbTethering batteryFloor thermalRelease
  sensorUnavailable reboot upgrade uninstall
)

fail() { print -u2 -- "$1"; exit "${2:-65}"; }
value() { /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null; }
sha256() { /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print tolower($1)}'; }
safe_sha256() { sha256 "$1" 2>/dev/null || print unavailable; }
utc_now() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }
timestamp_epoch() {
  /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

valid_case() {
  local wanted=$1 test_case
  for test_case in "${required_cases[@]}"; do
    [[ "${wanted}" == "${test_case}" ]] && return 0
  done
  return 1
}

automated_case() {
  case "$1" in
    acquireRelease|helperBoundary|supervisorCrash|helperCrash|timedAssertionExpiry) return 0 ;;
    *) return 1 ;;
  esac
}

describe_case() {
  local test_case=$1 mode safety procedure pass_criteria
  valid_case "${test_case}" || fail "알 수 없는 시험 항목: ${test_case}" 64
  if automated_case "${test_case}"; then
    mode=automated
  else
    mode=manual
  fi

  case "${test_case}" in
    cleanInstall)
      safety='기존 Runtinue와 레거시 SafeClam 구성요소가 없고 SleepDisabled=No인지 확인한다. 덮개를 연 통풍되는 장소에서 작업을 백업하고, 고정 manifest와 패키지 SHA-256 및 관리자 동의를 다시 확인한다.'
      procedure='begin 기록 후 install-package.sh의 읽기 전용 검사를 먼저 실행한다. 같은 패키지에 --apply와 --allow-power-mutation을 명시해 설치하고 verify-installation.sh --runtime, runtinue status를 확인한 뒤 모든 모드를 중단한다.'
      pass_criteria='manifest에 고정된 파일과 서비스만 설치되고 runtime 정합성 검사와 CLI 상태 조회가 성공한다. 종료 시 모드는 비활성이며 SleepDisabled=No이다.'
      ;;
    acquireRelease)
      safety='설치된 후보가 manifest와 일치하고 로그인 사용자 Terminal에서 덮개를 연 채 SleepDisabled=No인지 확인한다. 유한 lease 동안 기기를 관찰할 수 있는 통풍되는 장소를 사용한다.'
      procedure='run 토큰을 확인하고 고정 integration-test.sh를 scenario 인자 없이 실행한다. runner가 2분 상한의 closed-lid 허용 lease를 획득하고 명시적으로 해제하도록 둔다.'
      pass_criteria='runner가 lease 중 SleepDisabled=Yes, 해제 뒤 SleepDisabled=No를 직접 확인하고 종료 코드 0을 반환한다. 후보와 runner SHA-256도 실행 전후 동일하다.'
      ;;
    helperBoundary)
      safety='설치된 root Helper와 Supervisor가 후보 manifest와 일치하고 SleepDisabled=No인지 확인한다. root Helper에 대한 임의 IPC 도구를 사용하지 않고 고정 runner만 사용한다.'
      procedure='run 토큰을 확인하고 고정 integration-test.sh를 scenario 인자 없이 실행한다. runner가 설치된 CLI의 verify-helper-boundary 검사를 수행하도록 둔다.'
      pass_criteria='Helper 서비스는 실행 중이지만 CLI의 직접 privileged 연결은 거부된다. 정상 Supervisor 경로의 유한 lease는 정리되고 종료 시 SleepDisabled=No이다.'
      ;;
    supervisorCrash)
      safety='후보와 runner SHA-256, SleepDisabled=No, 열린 덮개와 통풍을 확인한다. 테스트 중 launchd가 Supervisor를 다시 시작할 수 있어야 하며 다른 보호 모드는 없어야 한다.'
      procedure='run 토큰을 확인하고 고정 integration-test.sh에 --supervisor-crash만 전달한다. runner가 유한 lease 활성화 뒤 Supervisor를 종료하고 정상 수면 복구를 기다리도록 둔다.'
      pass_criteria='Supervisor 비정상 종료 뒤 제한 시간 안에 SleepDisabled=No로 복구되고 runner가 종료 코드 0을 반환한다. 후보와 runner SHA-256은 변하지 않는다.'
      ;;
    helperCrash)
      safety='후보와 runner SHA-256, sudo 인증 준비, SleepDisabled=No, 열린 덮개와 통풍을 확인한다. launchd가 Helper를 다시 시작할 수 있어야 하며 다른 보호 모드는 없어야 한다.'
      procedure='run 토큰을 확인하고 고정 integration-test.sh에 --helper-crash만 전달한다. runner가 유한 lease 활성화 뒤 Helper를 종료하고 정상 수면 복구와 서비스 재기동을 기다리도록 둔다.'
      pass_criteria='Helper 비정상 종료 뒤 제한 시간 안에 SleepDisabled=No로 복구되고 Helper가 다시 로드되며 runner가 종료 코드 0을 반환한다.'
      ;;
    timedAssertionExpiry)
      safety='설치된 후보와 runner SHA-256, 열린 덮개, 통풍, SleepDisabled=No 및 기존 Runtinue desk assertion 부재를 확인한다. 이 case에서는 privileged closed-lid lease를 사용하지 않는다.'
      procedure='run 토큰을 확인하고 고정 integration-test.sh에 --timed-assertion-timeout만 전달한다. runner가 15초 open-lid assertion을 만든 뒤 Supervisor를 정지해 운영체제 timeout만으로 active assertion이 사라지는지 확인하도록 둔다.'
      pass_criteria='Supervisor가 정지된 동안 Runtinue assertion이 active 목록에서 제한 시간 안에 사라진다. 재개 뒤 session은 idle 또는 ended이고 시험 전후 SleepDisabled=No이다.'
      ;;
    closedLid15Minutes)
      safety='배터리가 적용 기준보다 충분히 높고 열 압력이 nominal이며 기기를 밀폐하지 않은 통풍되는 단단한 표면이어야 한다. 다른 모드를 중단하고 SleepDisabled=No를 확인하며 실험자가 15분 동안 기기를 관찰한다.'
      procedure='begin 기록 후 runtinue desk enable --max 20m --closed-lid를 실행해 protected 상태를 확인한다. 덮개를 15분 이상 닫았다가 열어 즉시 상태와 종료 사유를 확인하고 desk disable 또는 stop으로 정리한다.'
      pass_criteria='덮개를 닫은 15분 동안 안전 중단 사유 없이 유한 보호가 유지되고 다시 연 뒤 명시적 중단이 성공한다. finish 시 SleepDisabled=No이며 기록 시간 간격은 900초 이상이다.'
      ;;
    acToBattery)
      safety='배터리가 적용 기준보다 충분히 높고 열 압력이 nominal인 열린 덮개와 통풍 환경을 사용한다. 전원 어댑터를 안전하게 분리할 수 있어야 하며 다른 모드와 기존 lease는 없어야 한다.'
      procedure='begin 기록 후 AC 전원에서 5분 상한의 closed-lid 허용 desk mode를 시작해 protected 상태를 확인한다. 덮개는 연 채 어댑터를 분리하고 status가 battery 전원을 관찰할 때까지 기다린 뒤 모드를 중단한다.'
      pass_criteria='status가 battery 전원을 관찰하고 배터리와 열 조건이 안전한 동안 같은 유한 session이 protected로 유지된다. 명시적 중단 뒤 SleepDisabled=No이다. 예기치 않은 안전 중단은 이 case의 실패로 기록한다.'
      ;;
    hotspotHandoff)
      safety='테스트용 휴대전화 핫스팟의 사용 허가와 데이터 여유, 충분한 배터리, nominal 열 상태, 열린 덮개와 통풍을 확인한다. SSID, 게이트웨이와 기기 식별자는 증거에 기록하지 않는다.'
      procedure='begin 기록 후 다른 네트워크에서 runtinue trip start --for 10m --hotspot <test-hotspot>을 시작한다. 표시된 대기 상태를 확인하고 제한 시간 안에 해당 핫스팟으로 전환해 route 확인과 protected 전환을 관찰한 뒤 stop한다.'
      pass_criteria='대상 핫스팟과 도달 가능한 기본 route가 확인되기 전에는 protected로 표시되지 않고, 확인 뒤 유한 session이 protected가 된다. stop 뒤 SleepDisabled=No이다.'
      ;;
    hotspotAlreadyConnected)
      safety='허가된 테스트 핫스팟에 이미 연결되어 있고 기본 route가 도달 가능하며 배터리와 열 상태가 안전한지 확인한다. 실제 SSID, 게이트웨이와 기기 식별자는 기록하지 않는다.'
      procedure='begin 기록 후 현재 테스트 핫스팟을 대상으로 runtinue trip start --for 10m --hotspot <test-hotspot> --already-connected를 실행한다. 초기 상태와 protected 전환을 확인한 뒤 stop한다.'
      pass_criteria='현재 SSID와 route를 새 기준선으로 명시적으로 확인한 뒤 유한 session이 protected가 된다. 다른 네트워크를 잘못 승인하지 않고 stop 뒤 SleepDisabled=No이다.'
      ;;
    usbTethering)
      safety='허가된 테스트 휴대전화와 케이블을 사용하고 휴대전화 배터리와 데이터 사용을 확인한다. Mac 배터리와 열 상태가 안전하고 덮개가 열려 있으며 Wi-Fi SSID, 인터페이스와 기기 식별자는 기록하지 않는다.'
      procedure='begin 기록 후 runtinue trip start --for 10m --usb-tether를 실행한다. USB 테더링을 연결해 비 Wi-Fi 기본 route와 protected 전환을 확인하고 케이블을 분리하기 전에 stop한다.'
      pass_criteria='USB 경로와 도달 가능한 기본 route가 확인된 뒤에만 유한 session이 protected가 된다. stop과 케이블 분리 뒤 session이 종료되고 SleepDisabled=No이다.'
      ;;
    batteryFloor)
      safety='외부 디스플레이 없이 배터리 30~39%, Low Power Mode, nominal 열 상태를 안전하게 준비할 수 있을 때만 수행한다. 배터리를 과방전하지 말고 덮개를 연 통풍 환경에서 시작하며 준비할 수 없으면 notRun으로 남긴다.'
      procedure='begin 기록 후 배터리 전원에서 runtinue desk enable --max 5m --closed-lid를 시작한다. 초기 protected 상태를 확인하고 덮개를 닫아 적용 배터리 하한이 현재 잔량보다 높아지게 한 뒤 자동 release를 기다리고 다시 덮개를 연다.'
      pass_criteria='배터리 하한 위반이 관찰되면 session이 batteryBelowFloor 안전 사유로 종료되고 privileged lease가 해제된다. 덮개를 연 뒤 SleepDisabled=No이다.'
      ;;
    thermalRelease)
      safety='Low Power Mode와 열린 덮개를 사용하고 기기를 통풍되는 단단한 표면에 둔다. 외부 열원, 밀폐, 통풍구 차단이나 무제한 부하는 금지하며 정상적인 bounded workload로 macOS thermal pressure fair를 안전하게 만들 수 없으면 notRun으로 남긴다.'
      procedure='begin 기록 후 nominal 상태에서 runtinue desk enable --max 10m을 시작한다. 한 번의 사전 승인된 bounded workload를 실행하면서 status를 관찰하고 thermal pressure가 정책 cutoff에 도달하면 workload를 즉시 중단한다.'
      pass_criteria='macOS thermal pressure가 cutoff에 도달하면 session이 thermalLimitReached 사유로 자동 종료된다. 추가 부하 없이 최종 상태가 inactive이고 시험 전후 SleepDisabled=No이다.'
      ;;
    sensorUnavailable)
      safety='운영체제가 배터리 또는 thermal 값을 자연스럽게 unavailable로 보고하는 경우에만 수행한다. 센서 분리, 커널·IORegistry 변경, powerd 종료나 하드웨어 방해로 장애를 만들지 말며 조건이 없으면 notRun으로 남긴다.'
      procedure='begin 전에 읽기 전용 inspect로 unavailable 범주만 확인하고 원본 출력을 저장하지 않는다. begin 후 2분 상한의 closed-lid 허용 desk mode 시작을 한 번 요청하고 status의 거부 또는 기존 session의 안전 종료를 확인한다.'
      pass_criteria='센서 값을 확인할 수 없으면 새 보호 요청이 거부되거나 기존 보호가 thermalUnavailable 또는 batteryUnavailable 안전 사유로 종료된다. 보호 성공으로 오표시되지 않고 SleepDisabled=No이다.'
      ;;
    reboot)
      safety='모든 Runtinue 모드를 중단하고 SleepDisabled=No인지 확인한 뒤 열린 덮개 상태에서 작업을 저장한다. 후보 패키지, manifest와 record를 유지하고 재부팅에 대한 명시적 동의를 받는다.'
      procedure='begin 기록 후 Mac을 정상 재시동한다. 같은 로그인 사용자로 돌아와 서비스 자동 시작, 설치 runtime 정합성, runtinue status와 SleepDisabled를 확인하고 필요하면 비활성 stop을 한 번 실행한다.'
      pass_criteria='재부팅 뒤 Helper와 Supervisor가 설치된 후보로 정상 로드되고 이전 보호 session을 임의로 재개하지 않는다. 상태는 idle 또는 ended이고 SleepDisabled=No이다.'
      ;;
    upgrade)
      safety='지원되는 이전 Runtinue 버전이 설치되어 있고 모든 모드가 중단되어 SleepDisabled=No인지 확인한다. 사용자 설정을 백업하고 목표 manifest와 패키지를 finish까지 보존하며 SHA-256, 열린 덮개, 통풍 및 관리자 동의를 확인한다.'
      procedure='begin 기록 후 목표 패키지의 install-package.sh 읽기 전용 검사를 수행하고 같은 패키지로 명시적 upgrade 설치를 실행한다. verify-installation.sh --runtime, 버전, status 및 보존되어야 할 사용자 설정을 확인한다.'
      pass_criteria='설치된 앱, CLI, Helper와 Supervisor가 모두 목표 후보 버전과 manifest에 일치하고 서비스가 응답한다. 사용자 설정은 보존되고 보호는 자동 재개되지 않으며 SleepDisabled=No이다.'
      ;;
    uninstall)
      safety='검증 대상 후보가 설치되어 있고 모든 모드를 중단한 뒤 SleepDisabled=No인지 확인한다. manifest와 패키지를 finish까지 보존하고 제거 후 사용자 설정이 보존된다는 범위를 확인하며 열린 덮개에서 관리자 동의를 받는다.'
      procedure='begin 기록 후 runtinue stop을 실행하고 설치된 후보와 같은 버전의 uninstall.sh를 sudo로 실행한다. 앱, CLI, launchd 서비스와 package receipt 부재를 읽기 전용으로 확인하고 사용자 설정 디렉터리는 삭제하지 않는다.'
      pass_criteria='시스템 앱, 실행 파일, Helper, Supervisor와 receipt가 제거되고 사용자 config, session과 history는 보존된다. 제거 전후 SleepDisabled=No이다.'
      ;;
  esac

  print -r -- "case: ${test_case}"
  print -r -- "execution mode: ${mode}"
  print -r -- "안전 전제: ${safety}"
  print -r -- "최소 절차: ${procedure}"
  print -r -- "통과 기준: ${pass_criteria}"
  print -r -- '증거 경계: begin/finish 또는 run이 기록하는 UTC 시각, 모델·macOS, 후보·runner SHA-256, SleepDisabled와 통과 여부만 보존한다. 개인 경로, 원본 로그, SSID·게이트웨이와 기기 식별자는 기록하지 않는다.'
}

sleep_disabled() {
  local output
  output=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null) || {
    print unknown
    return
  }
  if print -r -- "${output}" | /usr/bin/grep -q '"SleepDisabled" = No'; then
    print No
  elif print -r -- "${output}" | /usr/bin/grep -q '"SleepDisabled" = Yes'; then
    print Yes
  else
    print unknown
  fi
}

validate_manifest_fields() {
  [[ "${package_sha}" =~ '^[0-9a-f]{64}$' && \
    "${source_commit}" =~ '^[0-9a-f]{40}$' ]] || \
    fail "패키지 또는 소스 식별자 형식 오류"
  [[ "${source_state}" == clean || "${source_state}" == dirty ]] || \
    fail "작업 트리 상태 형식 오류"
  case "${signature_status}" in
    unsigned-development|signed-notarized|signed-installer-not-notarized) ;;
    *) fail "서명 상태 형식 오류" ;;
  esac
}

load_manifest() {
  local manifest_path=$1
  [[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] || \
    fail "일반 manifest 파일이 필요합니다" 66
  manifest=${manifest_path:A}
  manifest_sha=$(sha256 "${manifest}") || fail "manifest SHA-256을 계산하지 못했습니다" 69
  package_sha=$(value "${manifest}" package.sha256) || fail "패키지 SHA-256이 없습니다"
  package_sha=${package_sha:l}
  source_commit=$(value "${manifest}" source.commitSHA) || fail "소스 commit이 없는 후보는 기록할 수 없습니다"
  source_commit=${source_commit:l}
  source_state=$(value "${manifest}" source.workingTreeState) || fail "소스 작업 트리 상태가 없습니다"
  signature_status=$(value "${manifest}" package.signatureStatus) || fail "서명 상태가 없습니다"
  validate_manifest_fields
  [[ "$(sha256 "${manifest}")" == "${manifest_sha}" ]] || fail "읽는 동안 manifest가 변경되었습니다"
}

load_candidate() {
  local package_path=$2
  load_manifest "$1"
  [[ -f "${package_path}" && ! -L "${package_path}" ]] || \
    fail "일반 후보 패키지 파일이 필요합니다" 66
  package=${package_path:A}
  actual_package_sha=$(sha256 "${package}") || fail "후보 패키지 SHA-256을 계산하지 못했습니다" 69
  [[ "${actual_package_sha}" == "${package_sha}" ]] || \
    fail "manifest와 후보 패키지 SHA-256이 일치하지 않습니다. 전원 변경을 거부합니다"
}

confirmation_token() {
  local operation=${1:u} test_case=$2 verdict=${3:-} runner_sha
  if [[ "${operation}" == FINISH ]]; then
    [[ "${verdict}" == passed || "${verdict}" == failed ]] || fail "finish token에는 passed 또는 failed가 필요합니다" 64
    if automated_case "${test_case}" && [[ "${verdict}" == passed ]]; then
      fail "자동 시험은 runner만 통과 처리할 수 있습니다: ${test_case}" 64
    fi
    print -r -- "RUNTINUE FINISH ${test_case} ${verdict:u} ${manifest_sha} ${package_sha}"
  else
    [[ "${operation}" == RUN || "${operation}" == BEGIN ]] || fail "token 작업은 run, begin 또는 finish입니다" 64
    if [[ "${operation}" == RUN ]]; then
      automated_case "${test_case}" || fail "이 시험 항목은 begin/finish 수동 확인을 사용합니다: ${test_case}" 64
      [[ -f "${hardware_script_dir}/integration-test.sh" && \
        ! -L "${hardware_script_dir}/integration-test.sh" && \
        -x "${hardware_script_dir}/integration-test.sh" ]] || \
        fail "고정 integration-test.sh runner가 필요합니다" 66
      runner_sha=$(sha256 "${hardware_script_dir}/integration-test.sh")
      print -r -- "RUNTINUE RUN ${test_case} ${manifest_sha} ${package_sha} ${runner_sha}"
    else
      automated_case "${test_case}" && fail "이 시험 항목은 고정 runner로 실행해야 합니다: ${test_case}" 64
      print -r -- "RUNTINUE BEGIN ${test_case} ${manifest_sha} ${package_sha}"
    fi
  fi
}

record_lock=''
update_tmp=''
acquire_record_lock() {
  record_lock="${1}.lock"
  /bin/mkdir -- "${record_lock}" 2>/dev/null || fail "다른 프로세스가 이 실기기 기록을 갱신 중입니다" 75
  trap '[[ -z "${update_tmp:-}" ]] || /bin/rm -f -- "${update_tmp}"; [[ -z "${record_lock:-}" ]] || /bin/rmdir -- "${record_lock}" 2>/dev/null || true' EXIT
}
release_record_lock() {
  [[ -z "${record_lock}" ]] || /bin/rmdir -- "${record_lock}" 2>/dev/null || true
  record_lock=''
  trap - EXIT
}

validate_record_binding() {
  local record=$1
  [[ -f "${record}" && ! -L "${record}" ]] || fail "실기기 검증 기록이 없어 배포를 보류합니다" 78
  [[ "$(value "${record}" schemaVersion)" == 2 && \
    "$(value "${record}" manifestSHA256)" == "${manifest_sha}" && \
    "$(value "${record}" packageSHA256)" == "${package_sha}" && \
    "$(value "${record}" sourceCommit)" == "${source_commit}" && \
    "$(value "${record}" sourceWorkingTreeState)" == "${source_state}" && \
    "$(value "${record}" signatureStatus)" == "${signature_status}" ]] || \
    fail "실기기 기록이 현재 후보 패키지와 일치하지 않습니다"
}

validate_current_hardware() {
  local record=$1 current_model current_macos
  current_model=$(/usr/sbin/sysctl -n hw.model) || fail "Mac 모델을 읽지 못했습니다" 69
  current_macos=$(/usr/bin/sw_vers -productVersion) || fail "macOS 버전을 읽지 못했습니다" 69
  [[ "$(value "${record}" hardware.model)" == "${current_model}" && \
    "$(value "${record}" hardware.macosVersion)" == "${current_macos}" ]] || \
    fail "기록을 만든 Mac 모델 또는 macOS와 현재 시험 환경이 다릅니다"
}

copy_record_for_update() {
  local record=$1
  update_tmp=$(/usr/bin/mktemp "${record:h}/.${record:t}.tmp.XXXXXX") || fail "임시 기록 파일을 만들지 못했습니다" 73
  /bin/cp -p -- "${record}" "${update_tmp}"
}

commit_record_update() {
  local record=$1
  /usr/bin/plutil -convert json -r "${update_tmp}"
  /bin/mv -f -- "${update_tmp}" "${record}"
  update_tmp=''
}

assert_fresh_case() {
  local record=$1 test_case=$2 case_status
  case_status=$(value "${record}" "tests.${test_case}.status") || fail "시험 상태를 읽지 못했습니다: ${test_case}"
  [[ "${case_status}" == notRun ]] || fail "이미 시작한 시험 기록을 덮어쓰지 않습니다: ${test_case}" 73
}

validate_runner_for_case() {
  local test_case=$1
  shift
  local runner=${1:A} expected_runner="${hardware_script_dir}/integration-test.sh"
  shift
  [[ "${runner}" == "${expected_runner}" ]] || \
    fail "자동 시험은 같은 scripts 디렉터리의 고정 integration-test.sh만 실행합니다" 66
  case "${test_case}" in
    acquireRelease|helperBoundary)
      (( $# == 0 )) || fail "${test_case} 자동 시험에는 scenario 인자를 사용하지 않습니다" 64
      ;;
    supervisorCrash)
      [[ $# -eq 1 && "$1" == --supervisor-crash ]] || fail "supervisorCrash runner 인자 오류" 64
      ;;
    helperCrash)
      [[ $# -eq 1 && "$1" == --helper-crash ]] || fail "helperCrash runner 인자 오류" 64
      ;;
    timedAssertionExpiry)
      [[ $# -eq 1 && "$1" == --timed-assertion-timeout ]] || fail "timedAssertionExpiry runner 인자 오류" 64
      ;;
    *) fail "이 시험 항목은 문서화한 수동 절차로 begin/finish 해야 합니다: ${test_case}" 64 ;;
  esac
}

create_record() {
  local record_path=$3 hardware_model hardware_macos created_at test_case record_tmp
  [[ ! -L "${record_path}" ]] || fail "실기기 기록 경로는 심볼릭 링크일 수 없습니다" 66
  local record=${record_path:A}
  load_candidate "$1" "$2"
  [[ ! -e "${record}" && ! -L "${record}" ]] || fail "기존 실기기 기록을 덮어쓰지 않습니다" 73
  hardware_model=$(/usr/sbin/sysctl -n hw.model) || fail "Mac 모델을 읽지 못했습니다" 69
  hardware_macos=$(/usr/bin/sw_vers -productVersion) || fail "macOS 버전을 읽지 못했습니다" 69
  created_at=$(utc_now)
  /bin/mkdir -p -- "${record:h}"
  record_tmp=$(/usr/bin/mktemp "${record}.tmp.XXXXXX") || fail "임시 기록 파일을 만들지 못했습니다" 73
  trap '/bin/rm -f -- "${record_tmp}"' EXIT
  /usr/bin/plutil -create xml1 "${record_tmp}"
  /usr/bin/plutil -insert schemaVersion -integer 2 "${record_tmp}"
  /usr/bin/plutil -insert manifestSHA256 -string "${manifest_sha}" "${record_tmp}"
  /usr/bin/plutil -insert packageSHA256 -string "${package_sha}" "${record_tmp}"
  /usr/bin/plutil -insert sourceCommit -string "${source_commit}" "${record_tmp}"
  /usr/bin/plutil -insert sourceWorkingTreeState -string "${source_state}" "${record_tmp}"
  /usr/bin/plutil -insert signatureStatus -string "${signature_status}" "${record_tmp}"
  /usr/bin/plutil -insert createdAt -string "${created_at}" "${record_tmp}"
  /usr/bin/plutil -insert hardware -dictionary "${record_tmp}"
  /usr/bin/plutil -insert hardware.model -string "${hardware_model}" "${record_tmp}"
  /usr/bin/plutil -insert hardware.macosVersion -string "${hardware_macos}" "${record_tmp}"
  /usr/bin/plutil -insert tests -dictionary "${record_tmp}"
  for test_case in "${required_cases[@]}"; do
    /usr/bin/plutil -insert "tests.${test_case}" -dictionary "${record_tmp}"
    /usr/bin/plutil -insert "tests.${test_case}.status" -string notRun "${record_tmp}"
    /usr/bin/plutil -insert "tests.${test_case}.executionMode" -string "" "${record_tmp}"
    /usr/bin/plutil -insert "tests.${test_case}.operatorConfirmed" -bool NO "${record_tmp}"
    /usr/bin/plutil -insert "tests.${test_case}.completionConfirmed" -bool NO "${record_tmp}"
    for field in startedAt endedAt startSleepDisabled endSleepDisabled result \
      startManifestSHA256 endManifestSHA256 startPackageSHA256 endPackageSHA256 \
      runnerName startRunnerSHA256 endRunnerSHA256; do
      /usr/bin/plutil -insert "tests.${test_case}.${field}" -string "" "${record_tmp}"
    done
  done
  /usr/bin/plutil -convert json -r "${record_tmp}"
  /bin/mv -n -- "${record_tmp}" "${record}"
  [[ ! -e "${record_tmp}" ]] || fail "동시에 생성된 기존 실기기 기록을 보존했습니다" 73
  trap - EXIT
  print "미실행 상태의 실기기 기록 생성: ${record}"
}

begin_case() {
  local manifest_path=$1 package_path=$2 record_path=$3 test_case=$4 confirmation=$5
  local expected start_state started
  [[ ! -L "${record_path}" ]] || fail "실기기 기록 경로는 심볼릭 링크일 수 없습니다" 66
  local record=${record_path:A}
  load_candidate "${manifest_path}" "${package_path}"
  valid_case "${test_case}" || fail "알 수 없는 시험 항목: ${test_case}" 64
  expected=$(confirmation_token begin "${test_case}")
  [[ "${confirmation}" == "${expected}" ]] || fail "정확한 begin 확인 토큰이 필요합니다. token 명령으로 생성하세요" 77
  acquire_record_lock "${record}"
  validate_record_binding "${record}"
  validate_current_hardware "${record}"
  assert_fresh_case "${record}" "${test_case}"
  start_state=$(sleep_disabled)
  [[ "${start_state}" == No ]] || fail "시험 시작 전 SleepDisabled=No를 확인하지 못했습니다" 70
  started=$(utc_now)
  copy_record_for_update "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.status" -string running "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.executionMode" -string manual "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.operatorConfirmed" -bool YES "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startedAt" -string "${started}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startSleepDisabled" -string "${start_state}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startManifestSHA256" -string "${manifest_sha}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startPackageSHA256" -string "${actual_package_sha}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.runnerName" -string manual "${update_tmp}"
  commit_record_update "${record}"
  release_record_lock
  print "수동 시험 시작 증거 기록: ${test_case}, ${started}, SleepDisabled=${start_state}"
}

finish_case() {
  local manifest_path=$1 package_path=$2 record_path=$3 test_case=$4 verdict=$5 confirmation=$6
  local expected mode case_status ended end_state end_manifest_sha end_package_sha final_status result
  [[ ! -L "${record_path}" ]] || fail "실기기 기록 경로는 심볼릭 링크일 수 없습니다" 66
  local record=${record_path:A}
  load_candidate "${manifest_path}" "${package_path}"
  valid_case "${test_case}" || fail "알 수 없는 시험 항목: ${test_case}" 64
  [[ "${verdict}" == passed || "${verdict}" == failed ]] || fail "완료 결과는 passed 또는 failed입니다" 64
  expected=$(confirmation_token finish "${test_case}" "${verdict}")
  [[ "${confirmation}" == "${expected}" ]] || fail "정확한 finish 확인 토큰이 필요합니다. token 명령으로 생성하세요" 77
  acquire_record_lock "${record}"
  validate_record_binding "${record}"
  validate_current_hardware "${record}"
  case_status=$(value "${record}" "tests.${test_case}.status")
  mode=$(value "${record}" "tests.${test_case}.executionMode")
  [[ "${case_status}" == running ]] || fail "실행 중인 시험만 완료할 수 있습니다: ${test_case}" 73
  [[ "${mode}" == manual || ( "${mode}" == automated && "${verdict}" == failed ) ]] || \
    fail "자동 실행은 도구만 통과 처리할 수 있습니다. 중단된 실행은 failed로만 종료하세요" 77
  ended=$(utc_now)
  end_state=$(sleep_disabled)
  end_manifest_sha=$(safe_sha256 "${manifest}")
  end_package_sha=$(safe_sha256 "${package}")
  final_status=${verdict}
  if [[ "${verdict}" == passed && ( "${end_state}" != No || \
    "${end_manifest_sha}" != "${manifest_sha}" || "${end_package_sha}" != "${package_sha}" ) ]]; then
    final_status=failed
  fi
  if [[ "${final_status}" == passed ]]; then
    result='Operator confirmed the documented manual procedure passed'
  else
    result='Operator confirmed the documented manual procedure failed'
  fi
  copy_record_for_update "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.status" -string "${final_status}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.completionConfirmed" -bool YES "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endedAt" -string "${ended}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endSleepDisabled" -string "${end_state}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endManifestSHA256" -string "${end_manifest_sha}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endPackageSHA256" -string "${end_package_sha}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.result" -string "${result}" "${update_tmp}"
  commit_record_update "${record}"
  release_record_lock
  [[ "${final_status}" == passed ]] || fail "시험 실패를 기록했습니다: ${test_case}" 78
  print "수동 시험 통과 증거 기록: ${test_case}, ${ended}, SleepDisabled=${end_state}"
}

run_case() {
  local manifest_path=$1 package_path=$2 record_path=$3 test_case=$4 confirmation=$5
  shift 5
  (( $# >= 1 )) || fail "실행할 절대 경로 명령이 필요합니다" 64
  local runner_argument=$1 runner=${1:A} expected start_state end_state started ended start_manifest end_manifest
  local -a runner_arguments
  runner_arguments=("${@:2}")
  local start_package end_package start_runner end_runner runner_status=0 final_status result
  [[ ! -L "${record_path}" ]] || fail "실기기 기록 경로는 심볼릭 링크일 수 없습니다" 66
  local record=${record_path:A}
  [[ "${runner_argument}" == /* && -f "${runner_argument}" && \
    ! -L "${runner_argument}" && -x "${runner_argument}" ]] || \
    fail "runner는 실행 가능한 일반 파일의 절대 경로여야 합니다" 66
  load_candidate "${manifest_path}" "${package_path}"
  valid_case "${test_case}" || fail "알 수 없는 시험 항목: ${test_case}" 64
  validate_runner_for_case "${test_case}" "${runner}" "${runner_arguments[@]}"
  start_manifest=${manifest_sha}
  start_package=$(sha256 "${package}")
  start_runner=$(sha256 "${runner}")
  expected="RUNTINUE RUN ${test_case} ${start_manifest} ${start_package} ${start_runner}"
  [[ "${confirmation}" == "${expected}" ]] || fail "정확한 run 확인 토큰이 필요합니다. token 명령으로 생성하세요" 77
  acquire_record_lock "${record}"
  validate_record_binding "${record}"
  validate_current_hardware "${record}"
  assert_fresh_case "${record}" "${test_case}"
  start_state=$(sleep_disabled)
  [[ "${start_state}" == No ]] || fail "시험 시작 전 SleepDisabled=No를 확인하지 못했습니다" 70
  [[ "$(sha256 "${manifest}")" == "${start_manifest}" && \
    "$(sha256 "${package}")" == "${start_package}" && \
    "$(sha256 "${runner}")" == "${start_runner}" && \
    "${start_package}" == "${package_sha}" ]] || fail "실행 직전 manifest, 후보 또는 runner가 변경되었습니다"
  started=$(utc_now)
  copy_record_for_update "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.status" -string running "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.executionMode" -string automated "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.operatorConfirmed" -bool YES "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startedAt" -string "${started}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startSleepDisabled" -string "${start_state}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startManifestSHA256" -string "${start_manifest}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startPackageSHA256" -string "${start_package}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.runnerName" -string "${runner:t}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.startRunnerSHA256" -string "${start_runner}" "${update_tmp}"
  commit_record_update "${record}"

  RUNTINUE_ALLOW_POWER_MUTATION=YES \
    RUNTINUE_EXPECTED_MANIFEST="${manifest}" \
    RUNTINUE_EXPECTED_PKG="${package}" \
    RUNTINUE_EXPECTED_SHA256="${package_sha}" \
    "${runner}" "${runner_arguments[@]}" || runner_status=$?

  ended=$(utc_now)
  end_state=$(sleep_disabled)
  end_manifest=$(safe_sha256 "${manifest}")
  end_package=$(safe_sha256 "${package}")
  end_runner=$(safe_sha256 "${runner}")
  final_status=failed
  result='Automated runner failed or safety evidence changed'
  if (( runner_status == 0 )) && [[ "${end_state}" == No && "${end_manifest}" == "${start_manifest}" && \
    "${end_package}" == "${package_sha}" && "${end_runner}" == "${start_runner}" ]]; then
    final_status=passed
    result='Automated runner exited 0; manifest, candidate, runner and SleepDisabled remained unchanged'
  fi
  copy_record_for_update "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.status" -string "${final_status}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.completionConfirmed" -bool YES "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endedAt" -string "${ended}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endSleepDisabled" -string "${end_state}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endManifestSHA256" -string "${end_manifest}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endPackageSHA256" -string "${end_package}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.endRunnerSHA256" -string "${end_runner}" "${update_tmp}"
  /usr/bin/plutil -replace "tests.${test_case}.result" -string "${result}" "${update_tmp}"
  commit_record_update "${record}"
  release_record_lock
  [[ "${final_status}" == passed ]] || fail "자동 시험 실패 또는 안전 증거 변경을 기록했습니다: ${test_case}" 78
  print "자동 시험 통과 증거 기록: ${test_case}, ${ended}, SleepDisabled=${end_state}"
}

verify_record() {
  local record_path=$3 record test_case model macos_version created created_epoch now_epoch case_status mode started ended
  local start_epoch end_epoch result runner_name start_runner end_runner approved_runner approved_runner_sha
  [[ ! -L "${record_path}" ]] || fail "실기기 기록 경로는 심볼릭 링크일 수 없습니다" 66
  load_candidate "$1" "$2"
  record=${record_path:A}
  validate_record_binding "${record}"
  model=$(value "${record}" hardware.model)
  macos_version=$(value "${record}" hardware.macosVersion)
  created=$(value "${record}" createdAt)
  [[ "${model}" =~ '^[A-Za-z0-9,._-]{1,128}$' && \
    "${macos_version}" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?$' ]] || \
    fail "실기기 모델과 macOS 버전이 필요합니다"
  now_epoch=$(/bin/date +%s)
  created_epoch=$(timestamp_epoch "${created}") || fail "기록 생성 시간 오류"
  (( created_epoch <= now_epoch )) || fail "기록 생성 시간이 미래입니다"
  approved_runner="${hardware_script_dir}/integration-test.sh"
  [[ -f "${approved_runner}" && ! -L "${approved_runner}" && -x "${approved_runner}" ]] || \
    fail "검증에 사용할 고정 integration-test.sh runner가 필요합니다" 66
  approved_runner_sha=$(sha256 "${approved_runner}") || fail "runner SHA-256을 계산하지 못했습니다" 69
  for test_case in "${required_cases[@]}"; do
    case_status=$(value "${record}" "tests.${test_case}.status")
    mode=$(value "${record}" "tests.${test_case}.executionMode")
    if automated_case "${test_case}"; then
      [[ "${mode}" == automated ]] || fail "고정 runner로 실행하지 않은 자동 시험: ${test_case}" 78
    else
      [[ "${mode}" == manual ]] || fail "수동 확인 방식이 아닌 시험 기록: ${test_case}" 78
    fi
    [[ "${case_status}" == passed && ( "${mode}" == manual || "${mode}" == automated ) && \
      "$(value "${record}" "tests.${test_case}.operatorConfirmed")" == true && \
      "$(value "${record}" "tests.${test_case}.completionConfirmed")" == true && \
      "$(value "${record}" "tests.${test_case}.startSleepDisabled")" == No && \
      "$(value "${record}" "tests.${test_case}.endSleepDisabled")" == No && \
      "$(value "${record}" "tests.${test_case}.startManifestSHA256")" == "${manifest_sha}" && \
      "$(value "${record}" "tests.${test_case}.endManifestSHA256")" == "${manifest_sha}" && \
      "$(value "${record}" "tests.${test_case}.startPackageSHA256")" == "${package_sha}" && \
      "$(value "${record}" "tests.${test_case}.endPackageSHA256")" == "${package_sha}" ]] || \
      fail "미실행, 실패, 미확인 또는 후보/수면 증거 오류: ${test_case}" 78
    started=$(value "${record}" "tests.${test_case}.startedAt")
    ended=$(value "${record}" "tests.${test_case}.endedAt")
    start_epoch=$(timestamp_epoch "${started}") || fail "시험 시작 시간 오류: ${test_case}"
    end_epoch=$(timestamp_epoch "${ended}") || fail "시험 종료 시간 오류: ${test_case}"
    (( created_epoch <= start_epoch && start_epoch <= end_epoch && end_epoch <= now_epoch )) || \
      fail "시험 시간 순서 오류: ${test_case}"
    if [[ "${test_case}" == closedLid15Minutes ]]; then
      (( end_epoch - start_epoch >= 900 )) || fail "덮개 닫힘 시험 기록은 최소 15분이어야 합니다" 78
    elif [[ "${test_case}" == timedAssertionExpiry ]]; then
      (( end_epoch - start_epoch >= 15 )) || fail "유한 assertion 만료 시험 기록은 최소 15초여야 합니다" 78
    fi
    result=$(value "${record}" "tests.${test_case}.result")
    runner_name=$(value "${record}" "tests.${test_case}.runnerName")
    start_runner=$(value "${record}" "tests.${test_case}.startRunnerSHA256")
    end_runner=$(value "${record}" "tests.${test_case}.endRunnerSHA256")
    if [[ "${mode}" == automated ]]; then
      [[ "${result}" == 'Automated runner exited 0; manifest, candidate, runner and SleepDisabled remained unchanged' && \
        "${runner_name}" =~ '^[A-Za-z0-9._-]{1,128}$' && \
        "${start_runner}" == "${approved_runner_sha}" && \
        "${end_runner}" == "${approved_runner_sha}" ]] || \
        fail "자동 runner 증거 오류: ${test_case}" 78
    else
      [[ "${result}" == 'Operator confirmed the documented manual procedure passed' && \
        "${runner_name}" == manual && -z "${start_runner}" && -z "${end_runner}" ]] || \
        fail "수동 수행 증거 오류: ${test_case}" 78
    fi
  done
  print "실기기 기록의 후보 일치, 수행 확인과 안전 복구 증거 확인 통과"
}

usage() {
  print -u2 '사용법:'
  print -u2 '  hardware-validation.sh cases'
  print -u2 '  hardware-validation.sh describe <case>'
  print -u2 '  hardware-validation.sh create <manifest.json> <package.pkg> <record.json>'
  print -u2 '  hardware-validation.sh token <manifest.json> <package.pkg> <case> run|begin'
  print -u2 '  hardware-validation.sh token <manifest.json> <package.pkg> <case> finish passed|failed'
  print -u2 '  hardware-validation.sh run <manifest.json> <package.pkg> <record.json> <case> --confirm <token> -- <absolute-runner> [args...]'
  print -u2 '  hardware-validation.sh begin <manifest.json> <package.pkg> <record.json> <case> --confirm <token>'
  print -u2 '  hardware-validation.sh finish <manifest.json> <package.pkg> <record.json> <case> passed|failed --confirm <token>'
  print -u2 '  hardware-validation.sh verify <manifest.json> <package.pkg> <record.json>'
  exit 64
}

action=${1:-}
case "${action}" in
  cases)
    [[ $# -eq 1 ]] || usage
    print -l -- "${required_cases[@]}"
    ;;
  describe)
    [[ $# -eq 2 ]] || usage
    describe_case "$2"
    ;;
  create)
    [[ $# -eq 4 ]] || usage
    create_record "$2" "$3" "$4"
    ;;
  token)
    [[ $# -eq 5 || $# -eq 6 ]] || usage
    load_candidate "$2" "$3"
    valid_case "$4" || fail "알 수 없는 시험 항목: $4" 64
    confirmation_token "$5" "$4" "${6:-}"
    ;;
  begin)
    [[ $# -eq 7 && "$6" == --confirm ]] || usage
    begin_case "$2" "$3" "$4" "$5" "$7"
    ;;
  finish)
    [[ $# -eq 8 && "$7" == --confirm ]] || usage
    finish_case "$2" "$3" "$4" "$5" "$6" "$8"
    ;;
  run)
    [[ $# -ge 9 && "$6" == --confirm && "$8" == -- ]] || usage
    manifest_arg=$2
    package_arg=$3
    record_arg=$4
    case_arg=$5
    confirmation_arg=$7
    shift 8
    run_case "${manifest_arg}" "${package_arg}" "${record_arg}" "${case_arg}" "${confirmation_arg}" "$@"
    ;;
  verify)
    [[ $# -eq 4 ]] || usage
    verify_record "$2" "$3" "$4"
    ;;
  *) usage ;;
esac
