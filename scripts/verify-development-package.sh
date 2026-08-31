#!/bin/zsh
set -euo pipefail

pkg=${1:-}
test -n "${pkg}" && test -f "${pkg}" || {
  print -u2 "사용법: verify-development-package.sh <development.pkg>"
  exit 64
}

signature_output=$(/usr/sbin/pkgutil --check-signature "${pkg}" 2>&1 || true)
print -r -- "${signature_output}" | /usr/bin/grep -q "Status: no signature" || {
  print -u2 "개발 패키지가 예상과 달리 unsigned 상태가 아님"
  exit 65
}

script_dir=${0:A:h}
"${script_dir}/verify-package-payload.sh" "${pkg}"
print "개발 패키지가 예상대로 unsigned 상태이며 payload 검증을 통과함"
