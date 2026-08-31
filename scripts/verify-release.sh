#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
pkg=${1:-}
test -n "${pkg}" && test -f "${pkg}" || {
  print -u2 "사용법: verify-release.sh <Runtinue.pkg>"
  exit 64
}

/usr/sbin/pkgutil --check-signature "${pkg}"
/usr/sbin/spctl -a -vv -t install "${pkg}"
/usr/bin/xcrun stapler validate "${pkg}"
"${script_dir}/verify-package-payload.sh" "${pkg}"

print "서명, Gatekeeper, staple과 실제 패키지 payload 검증 통과"
