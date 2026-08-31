#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
pkg=${1:-}
shift || true
expected_sha256=""
manifest=""
apply=NO
allow_power_mutation=NO

usage() {
  print -u2 "사용법: rollback-package.sh <SafeClam.pkg> --sha256 <64자리 SHA-256> --manifest <manifest.json> [--apply --allow-power-mutation]"
  exit 64
}

fail() {
  local code=${2:-66}
  print -u2 -- "$1"
  exit "${code}"
}

[[ -n "${pkg}" ]] || usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha256)
      [[ $# -ge 2 ]] || usage
      expected_sha256=$2
      shift 2
      ;;
    --manifest)
      [[ $# -ge 2 ]] || usage
      manifest=$2
      shift 2
      ;;
    --apply)
      apply=YES
      shift
      ;;
    --allow-power-mutation)
      allow_power_mutation=YES
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -f "${pkg}" ]] || fail "rollback 패키지를 찾을 수 없음: ${pkg}"
[[ -n "${manifest}" ]] || fail "rollback manifest를 명시해야 함" 64
[[ -n "${expected_sha256}" ]] || fail "rollback 예상 SHA-256을 --sha256로 명시해야 함" 64
[[ "${expected_sha256}" =~ '^[0-9a-fA-F]{64}$' ]] || fail "SHA-256 형식 오류" 64

actual_sha256=$(/usr/bin/shasum -a 256 -- "${pkg}" | /usr/bin/awk '{print $1}')
[[ "${actual_sha256:l}" == "${expected_sha256:l}" ]] || fail "rollback 패키지 SHA-256 불일치. 실행하지 않음" 65
manifest_sha256=$(/usr/bin/plutil -extract package.sha256 raw "${manifest}" 2>/dev/null) || \
  fail "rollback manifest package.sha256를 읽을 수 없음" 65
[[ "${manifest_sha256:l}" == "${actual_sha256:l}" ]] || fail "rollback 패키지와 manifest SHA-256 불일치" 65

# 현재 소스와의 cmp는 rollback 대상의 고정 sidecar 검증을 대신할 수 없다.
# sidecar가 기록한 payload와 설치 스크립트 hash, 서명 경계를 검증한다.
"${script_dir}/release-manifest.sh" verify "${pkg}" "${manifest}" --rollback >/dev/null
print "고정 rollback 패키지와 manifest 정합성 검증 통과"
print "rollback 대상 SHA-256: ${actual_sha256}"
print "rollback 실행 여부: ${apply}"

if [[ "${allow_power_mutation}" == YES && "${apply}" != YES ]]; then
  fail "--allow-power-mutation은 --apply와 함께 사용해야 함" 64
fi
if [[ "${apply}" != YES ]]; then
  print "rollback하지 않음. 실제 rollback에는 --apply와 --allow-power-mutation이 모두 필요함"
  exit 0
fi

[[ "${allow_power_mutation}" == YES ]] || \
  fail "rollback은 --allow-power-mutation 명시 없이는 실행하지 않음" 77
uid=$(/usr/bin/id -u)
[[ "${uid}" == 0 ]] || fail "실제 rollback 설치는 root로 실행해야 함" 77

/usr/sbin/installer -pkg "${pkg}" -target /
"${script_dir}/verify-installation.sh" "${manifest}" --pkg "${pkg}" --runtime --rollback
print "rollback 설치와 runtime 정합성 검증 완료"
