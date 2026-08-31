#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
release_root=${RUNTINUE_RELEASE_ROOT:-"${project_root}/.release"}
release_root=${release_root:A}
version=${VERSION:-0.2.0}
notary_profile=${NOTARY_KEYCHAIN_PROFILE:?NOTARY_KEYCHAIN_PROFILE을 지정해야 합니다}
pkg="${release_root}/Runtinue-${version}.pkg"

VERSION="${version}" "${script_dir}/package.sh"
/usr/bin/xcrun notarytool submit "${pkg}" --keychain-profile "${notary_profile}" --wait
/usr/bin/xcrun stapler staple "${pkg}"
/usr/bin/xcrun stapler validate "${pkg}"
/usr/sbin/spctl -a -vv -t install "${pkg}"
"${script_dir}/verify-release.sh" "${pkg}"

manifest="${pkg}.manifest.json"
RUNTINUE_NOTARIZATION_VERIFIED=YES \
  "${script_dir}/release-manifest.sh" create "${pkg}" "${manifest}" release
RUNTINUE_NOTARIZATION_VERIFIED=YES \
  "${script_dir}/release-manifest.sh" publish \
    "${pkg}" "${manifest}" "${project_root}/.release/Runtinue-latest.json"

checksum_file="${pkg}.sha256"
checksum=$(/usr/bin/shasum -a 256 -- "${pkg}" | /usr/bin/awk '{print $1}')
if [[ -e "${checksum_file}" || -L "${checksum_file}" ]]; then
  existing_checksum=$(/usr/bin/awk '{print $1}' "${checksum_file}")
  [[ "${existing_checksum:l}" == "${checksum:l}" ]] || {
    print -u2 "기존 checksum sidecar가 달라 덮어쓰지 않음: ${checksum_file}"
    exit 73
  }
else
  checksum_tmp=$(/usr/bin/mktemp "${checksum_file}.tmp.XXXXXX")
  print -r -- "${checksum}  ${pkg:t}" > "${checksum_tmp}"
  /bin/mv -- "${checksum_tmp}" "${checksum_file}"
fi

print "공증과 staple이 완료된 배포물: ${pkg}"
