#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
test_root=$(/usr/bin/mktemp -d /tmp/runtinue-hardware-record-tests.XXXXXX)
trap '/bin/rm -rf -- "${test_root}"' EXIT
script_dir="${test_root}/scripts"
/bin/mkdir -p "${script_dir}"

# 제품 스크립트의 사본에서 읽기 전용 기기 조회만 fixture로 바꾼다. 이 검사는
# 제품의 integration-test.sh를 실행하지 않으며 실제 설치나 전원 설정을 변경하지 않는다.
/usr/bin/printf '%s\n' \
  '#!/bin/zsh' \
  'state=$(/bin/cat "${0:A:h}/sleep-state")' \
  'print -r -- "\"SleepDisabled\" = ${state}"' > "${test_root}/ioreg-fixture"
/bin/chmod +x "${test_root}/ioreg-fixture"
print -r -- No > "${test_root}/sleep-state"
/usr/bin/sed \
  -e 's|/usr/sbin/sysctl -n hw.model|/usr/bin/printf FixtureMac|g' \
  -e 's|/usr/bin/sw_vers -productVersion|/usr/bin/printf 26.0|g' \
  -e "s|/usr/sbin/ioreg -r -n IOPMrootDomain -d 1|${test_root}/ioreg-fixture|g" \
  "${source_dir}/hardware-validation.sh" > "${script_dir}/hardware-validation.sh"
/bin/chmod +x "${script_dir}/hardware-validation.sh"
/usr/bin/printf '%s\n' \
  '#!/bin/zsh' \
  '[[ "${RUNTINUE_FIXTURE_RUNNER_EXIT:-0}" == 0 ]]' > "${script_dir}/integration-test.sh"
/bin/chmod +x "${script_dir}/integration-test.sh"

manifest="${test_root}/fixture.manifest.json"
package="${test_root}/Runtinue.pkg"
record="${test_root}/fixture.record.json"
failed_record="${test_root}/failed.record.json"
print -r -- 'fixed package fixture' > "${package}"
package_sha=$(/usr/bin/shasum -a 256 -- "${package}" | /usr/bin/awk '{print $1}')
/usr/bin/plutil -create xml1 "${manifest}"
/usr/bin/plutil -insert package -dictionary "${manifest}"
/usr/bin/plutil -insert package.sha256 -string "${package_sha}" "${manifest}"
/usr/bin/plutil -insert package.signatureStatus -string unsigned-development "${manifest}"
/usr/bin/plutil -insert source -dictionary "${manifest}"
/usr/bin/plutil -insert source.commitSHA -string 0000000000000000000000000000000000000000 "${manifest}"
/usr/bin/plutil -insert source.workingTreeState -string dirty "${manifest}"
/usr/bin/plutil -convert json "${manifest}"

passed=0
expect_exit() {
  local expected=$1
  shift
  local actual=0
  "$@" > "${test_root}/result" 2>&1 || actual=$?
  [[ "${actual}" -eq "${expected}" ]] || {
    print -u2 "실기기 기록 검사 예상 ${expected}, 실제 ${actual}: $*"
    /usr/bin/sed -n '1,20p' "${test_root}/result" >&2
    exit 1
  }
  passed=$((passed + 1))
}
expect_value() {
  local file=$1 key=$2 expected=$3 actual
  actual=$(/usr/bin/plutil -extract "${key}" raw "${file}") || {
    print -u2 "기록 필드를 읽지 못했습니다: ${key}"
    exit 1
  }
  [[ "${actual}" == "${expected}" ]] || {
    print -u2 "기록 필드 불일치 ${key}: 예상 ${expected}, 실제 ${actual}"
    exit 1
  }
  passed=$((passed + 1))
}
expect_line() {
  local output=$1 expected=$2
  print -r -- "${output}" | /usr/bin/grep -Fqx -- "${expected}" || {
    print -u2 "출력에 정확한 행이 없습니다: ${expected}"
    exit 1
  }
  passed=$((passed + 1))
}
expect_nonempty_field() {
  local output=$1 field=$2
  print -r -- "${output}" | /usr/bin/awk -v prefix="${field}: " '
    index($0, prefix) == 1 && substr($0, length(prefix) + 1) ~ /[^[:space:]]/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' || {
    print -u2 "출력 필드가 없거나 비어 있습니다: ${field}"
    exit 1
  }
  passed=$((passed + 1))
}

harness=(/bin/zsh "${script_dir}/hardware-validation.sh")

# 필수 case 목록과 실행 가능한 설명 계약은 서로 독립된 고정 기대값으로 검사한다.
# cases 출력만 순회하면 case가 실수로 함께 삭제된 회귀를 찾을 수 없다.
expected_cases=(
  cleanInstall acquireRelease helperBoundary supervisorCrash helperCrash
  timedAssertionExpiry closedLid15Minutes acToBattery hotspotHandoff
  hotspotAlreadyConnected usbTethering batteryFloor thermalRelease
  sensorUnavailable reboot upgrade uninstall
)
actual_cases=("${(@f)$("${harness[@]}" cases)}")
[[ "${(j:\n:)actual_cases}" == "${(j:\n:)expected_cases}" ]] || {
  print -u2 "필수 실기기 case 목록이 고정 계약과 다릅니다"
  exit 1
}
passed=$((passed + 1))
for test_case in "${expected_cases[@]}"; do
  description=$("${harness[@]}" describe "${test_case}")
  [[ "${description}" == "$("${harness[@]}" describe "${test_case}")" ]] || {
    print -u2 "case 설명은 같은 입력에 결정적이어야 합니다: ${test_case}"
    exit 1
  }
  passed=$((passed + 1))
  expect_line "${description}" "case: ${test_case}"
  expected_mode=manual
  case "${test_case}" in
    acquireRelease|helperBoundary|supervisorCrash|helperCrash|timedAssertionExpiry)
      expected_mode=automated
      ;;
  esac
  expect_line "${description}" "execution mode: ${expected_mode}"
  for field in '안전 전제' '최소 절차' '통과 기준' '증거 경계'; do
    expect_nonempty_field "${description}" "${field}"
  done
done
expect_exit 64 "${harness[@]}" describe
expect_exit 64 "${harness[@]}" describe cleanInstall extra
expect_exit 64 "${harness[@]}" describe unknownCase

expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
expect_exit 0 "${harness[@]}" create "${manifest}" "${package}" "${record}"
expect_exit 73 "${harness[@]}" create "${manifest}" "${package}" "${record}"
expect_value "${record}" schemaVersion 2
expect_value "${record}" manifestSHA256 \
  "$(/usr/bin/shasum -a 256 -- "${manifest}" | /usr/bin/awk '{print $1}')"
expect_value "${record}" packageSHA256 "${package_sha}"
expect_value "${record}" hardware.model FixtureMac
expect_value "${record}" hardware.macosVersion 26.0
expect_exit 64 "${harness[@]}" token "${manifest}" "${package}" acquireRelease begin
expect_exit 64 "${harness[@]}" token "${manifest}" "${package}" cleanInstall run
expect_exit 64 "${harness[@]}" token "${manifest}" "${package}" helperCrash finish passed

# 자동 실행은 정확한 후보별 확인 토큰 없이는 시작되지 않는다.
run_token=$("${harness[@]}" token "${manifest}" "${package}" acquireRelease run)
/bin/cp "${script_dir}/integration-test.sh" "${test_root}/integration-test.original"
print -r -- '# changed after confirmation' >> "${script_dir}/integration-test.sh"
expect_exit 77 "${harness[@]}" run "${manifest}" "${package}" "${record}" \
  acquireRelease --confirm "${run_token}" -- "${script_dir}/integration-test.sh"
/bin/cp "${test_root}/integration-test.original" "${script_dir}/integration-test.sh"
/bin/chmod +x "${script_dir}/integration-test.sh"
expect_exit 77 "${harness[@]}" run "${manifest}" "${package}" "${record}" \
  acquireRelease --confirm wrong -- "${script_dir}/integration-test.sh"
expect_exit 0 "${harness[@]}" run "${manifest}" "${package}" "${record}" \
  acquireRelease --confirm "${run_token}" -- "${script_dir}/integration-test.sh"
expect_value "${record}" tests.acquireRelease.status passed
expect_value "${record}" tests.acquireRelease.executionMode automated
expect_value "${record}" tests.acquireRelease.startSleepDisabled No
expect_value "${record}" tests.acquireRelease.endSleepDisabled No
expect_value "${record}" tests.acquireRelease.startManifestSHA256 \
  "$(/usr/bin/shasum -a 256 -- "${manifest}" | /usr/bin/awk '{print $1}')"
expect_value "${record}" tests.acquireRelease.endManifestSHA256 \
  "$(/usr/bin/shasum -a 256 -- "${manifest}" | /usr/bin/awk '{print $1}')"
expect_value "${record}" tests.acquireRelease.startPackageSHA256 "${package_sha}"
expect_value "${record}" tests.acquireRelease.endPackageSHA256 "${package_sha}"
expect_value "${record}" tests.acquireRelease.runnerName integration-test.sh
expect_exit 73 "${harness[@]}" run "${manifest}" "${package}" "${record}" \
  acquireRelease --confirm "${run_token}" -- "${script_dir}/integration-test.sh"

# 수동 시험도 시작과 결과에 각각 후보별 확인이 필요하다.
begin_token=$("${harness[@]}" token "${manifest}" "${package}" cleanInstall begin)
finish_token=$("${harness[@]}" token "${manifest}" "${package}" cleanInstall finish passed)
/usr/bin/plutil -replace hardware.model -string OtherMac "${record}"
expect_exit 65 "${harness[@]}" begin "${manifest}" "${package}" "${record}" \
  cleanInstall --confirm "${begin_token}"
/usr/bin/plutil -replace hardware.model -string FixtureMac "${record}"
expect_exit 0 "${harness[@]}" begin "${manifest}" "${package}" "${record}" \
  cleanInstall --confirm "${begin_token}"
expect_value "${record}" tests.cleanInstall.status running
expect_exit 77 "${harness[@]}" finish "${manifest}" "${package}" "${record}" \
  cleanInstall passed --confirm wrong
expect_exit 0 "${harness[@]}" finish "${manifest}" "${package}" "${record}" \
  cleanInstall passed --confirm "${finish_token}"
expect_value "${record}" tests.cleanInstall.status passed
expect_value "${record}" tests.cleanInstall.executionMode manual
expect_exit 73 "${harness[@]}" finish "${manifest}" "${package}" "${record}" \
  cleanInstall passed --confirm "${finish_token}"

# SleepDisabled가 정상 상태가 아니면 runner를 호출하기 전에 거부한다.
print -r -- Yes > "${test_root}/sleep-state"
blocked_token=$("${harness[@]}" token "${manifest}" "${package}" helperBoundary run)
expect_exit 66 "${harness[@]}" run "${manifest}" "${package}" "${record}" \
  helperBoundary --confirm "${blocked_token}" -- /usr/bin/true
expect_exit 70 "${harness[@]}" run "${manifest}" "${package}" "${record}" \
  helperBoundary --confirm "${blocked_token}" -- "${script_dir}/integration-test.sh"
expect_value "${record}" tests.helperBoundary.status notRun
print -r -- No > "${test_root}/sleep-state"

# 실패 runner도 실패와 종료 증거를 남기며 다시 실행해 덮어쓸 수 없다.
expect_exit 0 "${harness[@]}" create "${manifest}" "${package}" "${failed_record}"
failure_token=$("${harness[@]}" token "${manifest}" "${package}" helperCrash run)
expect_exit 78 /usr/bin/env RUNTINUE_FIXTURE_RUNNER_EXIT=1 \
  "${harness[@]}" run "${manifest}" "${package}" "${failed_record}" \
  helperCrash --confirm "${failure_token}" -- "${script_dir}/integration-test.sh" --helper-crash
expect_value "${failed_record}" tests.helperCrash.status failed
expect_value "${failed_record}" tests.helperCrash.completionConfirmed true
expect_exit 73 "${harness[@]}" run "${manifest}" "${package}" "${failed_record}" \
  helperCrash --confirm "${failure_token}" -- "${script_dir}/integration-test.sh" --helper-crash

# 같은 이름의 다른 바이트는 manifest 후보로 인정하지 않는다.
mismatched_package="${test_root}/Runtinue-mismatch.pkg"
print -r -- 'different bytes' > "${mismatched_package}"
expect_exit 65 "${harness[@]}" create "${manifest}" "${mismatched_package}" \
  "${test_root}/mismatch.record.json"
expect_exit 65 "${harness[@]}" token "${manifest}" "${mismatched_package}" reboot begin

# 아래 값은 verifier의 누락/변조 거부 경로를 검사하는 합성 fixture다. 실제 시험
# 결과가 아니며 생성된 임시 디렉터리는 테스트 종료 시 삭제된다.
test_cases=("${(@f)$("${harness[@]}" cases)}")
manifest_fixture_sha=$(/usr/bin/shasum -a 256 -- "${manifest}" | /usr/bin/awk '{print $1}')
runner_fixture_sha=$(/usr/bin/shasum -a 256 -- "${script_dir}/integration-test.sh" | /usr/bin/awk '{print $1}')
/usr/bin/plutil -replace createdAt -string '2025-01-01T00:00:00Z' "${record}"
for test_case in "${test_cases[@]}"; do
  /usr/bin/plutil -replace "tests.${test_case}.status" -string passed "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.operatorConfirmed" -bool YES "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.completionConfirmed" -bool YES "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.startSleepDisabled" -string No "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.endSleepDisabled" -string No "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.startManifestSHA256" -string \
    "${manifest_fixture_sha}" "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.endManifestSHA256" -string \
    "${manifest_fixture_sha}" "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.startPackageSHA256" -string "${package_sha}" "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.endPackageSHA256" -string "${package_sha}" "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.startedAt" -string '2025-01-01T00:00:00Z' "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.endedAt" -string '2025-01-01T00:15:00Z' "${record}"
  case "${test_case}" in
    acquireRelease|helperBoundary|supervisorCrash|helperCrash|timedAssertionExpiry)
      /usr/bin/plutil -replace "tests.${test_case}.executionMode" -string automated "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.runnerName" -string integration-test.sh "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.startRunnerSHA256" -string "${runner_fixture_sha}" "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.endRunnerSHA256" -string "${runner_fixture_sha}" "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.result" -string \
        'Automated runner exited 0; manifest, candidate, runner and SleepDisabled remained unchanged' "${record}"
      ;;
    *)
      /usr/bin/plutil -replace "tests.${test_case}.executionMode" -string manual "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.runnerName" -string manual "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.startRunnerSHA256" -string '' "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.endRunnerSHA256" -string '' "${record}"
      /usr/bin/plutil -replace "tests.${test_case}.result" -string \
        'Operator confirmed the documented manual procedure passed' "${record}"
      ;;
  esac
done
expect_exit 0 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${record}" "${test_root}/complete.json"

# 후보 필드가 같더라도 manifest 바이트가 바뀌면 기존 기록을 재사용할 수 없다.
/bin/cp "${manifest}" "${test_root}/manifest.complete.json"
/usr/bin/plutil -insert fixtureNote -string changed "${manifest}"
expect_exit 65 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/manifest.complete.json" "${manifest}"

for test_case in "${test_cases[@]}"; do
  /usr/bin/plutil -replace "tests.${test_case}.status" -string notRun "${record}"
  expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
  /bin/cp "${test_root}/complete.json" "${record}"
done
for field in manifestSHA256 packageSHA256 sourceCommit signatureStatus sourceWorkingTreeState; do
  /usr/bin/plutil -replace "${field}" -string mismatch "${record}"
  expect_exit 65 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
  /bin/cp "${test_root}/complete.json" "${record}"
done
/usr/bin/plutil -replace tests.acToBattery.endSleepDisabled -string Yes "${record}"
expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.acquireRelease.executionMode -string manual "${record}"
expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.reboot.endManifestSHA256 -string mismatch "${record}"
expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.closedLid15Minutes.endedAt -string '2025-01-01T00:14:59Z' "${record}"
expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.timedAssertionExpiry.endedAt -string '2025-01-01T00:00:14Z' "${record}"
expect_exit 78 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace createdAt -string '2025-01-02T00:00:00Z' "${record}"
expect_exit 65 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.reboot.endedAt -string '2999-01-01T00:15:00Z' "${record}"
expect_exit 65 "${harness[@]}" verify "${manifest}" "${package}" "${record}"
print "실기기 harness 후보 고정, 확인, 증거와 거부 경로 검사 ${passed}개 통과. 실제 전원 변경 없음"
