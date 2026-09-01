#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
test_root=$(/usr/bin/mktemp -d /tmp/runtinue-hardware-record-tests.XXXXXX)
trap '/bin/rm -rf -- "${test_root}"' EXIT
# 제품 코드의 사본에서 읽기 전용 기기 식별 조회만 고정한다. 실제 기기와 권한에 의존하지 않는다.
source_script="${script_dir}/hardware-validation.sh"
script_dir="${test_root}/scripts"
/bin/mkdir -p "${script_dir}"
/usr/bin/sed \
  -e 's|/usr/sbin/sysctl -n hw.model|/usr/bin/printf FixtureMac|g' \
  -e 's|/usr/bin/sw_vers -productVersion|/usr/bin/printf 26.0|g' \
  "${source_script}" > "${script_dir}/hardware-validation.sh"
manifest="${test_root}/fixture.manifest.json"
record="${test_root}/fixture.record.json"
/usr/bin/plutil -create xml1 "${manifest}"
/usr/bin/plutil -insert package -dictionary "${manifest}"
/usr/bin/plutil -insert package.sha256 -string \
  0000000000000000000000000000000000000000000000000000000000000000 "${manifest}"
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
    /usr/bin/sed -n '1,15p' "${test_root}/result" >&2
    exit 1
  }
  passed=$((passed + 1))
}
expect_exit 78 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
expect_exit 0 /bin/zsh "${script_dir}/hardware-validation.sh" create "${manifest}" "${record}"
expect_exit 73 /bin/zsh "${script_dir}/hardware-validation.sh" create "${manifest}" "${record}"
expect_exit 78 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
/usr/bin/plutil -replace operatorConfirmed -bool YES "${record}"
expect_exit 78 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"

# 아래 값은 도구의 거부 경로를 검사하는 가짜 기록이다. 실제 시험 결과로 게시하지 않는다.
test_cases=("${(@f)$(/bin/zsh "${script_dir}/hardware-validation.sh" cases)}")
for test_case in "${test_cases[@]}"; do
  /usr/bin/plutil -replace "tests.${test_case}.status" -string passed "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.startSleepDisabled" -string No "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.endSleepDisabled" -string No "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.startedAt" -string '2025-01-01T00:00:00Z' "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.endedAt" -string '2025-01-01T00:15:00Z' "${record}"
  /usr/bin/plutil -replace "tests.${test_case}.result" -string 'Synthetic fixture, not hardware evidence' "${record}"
done
expect_exit 0 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
/bin/cp "${record}" "${test_root}/complete.json"

for test_case in "${test_cases[@]}"; do
  /usr/bin/plutil -replace "tests.${test_case}.status" -string notRun "${record}"
  expect_exit 78 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
  /bin/cp "${test_root}/complete.json" "${record}"
done
for field in packageSHA256 sourceCommit signatureStatus sourceWorkingTreeState; do
  /usr/bin/plutil -replace "${field}" -string mismatch "${record}"
  expect_exit 65 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
  /bin/cp "${test_root}/complete.json" "${record}"
done
/usr/bin/plutil -replace tests.acToBattery.endSleepDisabled -string Yes "${record}"
expect_exit 78 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.closedLid15Minutes.endedAt -string '2025-01-01T00:14:59Z' "${record}"
expect_exit 78 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
/bin/cp "${test_root}/complete.json" "${record}"
/usr/bin/plutil -replace tests.reboot.endedAt -string '2999-01-01T00:15:00Z' "${record}"
expect_exit 65 /bin/zsh "${script_dir}/hardware-validation.sh" verify "${manifest}" "${record}"
print "실기기 기록 대상, 누락과 복구 상태 검사 ${passed}개 통과. 실제 전원 변경 없음"
