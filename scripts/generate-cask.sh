#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
version=$(/bin/zsh "${script_dir}/version.sh")
url=${RELEASE_URL:?RELEASE_URL을 지정해야 합니다}
homepage=${HOMEPAGE_URL:?HOMEPAGE_URL을 지정해야 합니다}
pkg=${PKG_PATH:?PKG_PATH를 지정해야 합니다}
output=${CASK_OUTPUT:-"${project_root}/Casks/runtinue.rb"}

[[ "${version}" =~ '^[0-9]+([.][0-9]+){1,3}$' ]] || {
  print -u2 "VERSION 형식이 올바르지 않음"
  exit 64
}
test -f "${pkg}" || {
  print -u2 "패키지를 찾을 수 없음: ${pkg}"
  exit 66
}
[[ "${url}" == https://* && "${homepage}" == https://* ]] || {
  print -u2 "RELEASE_URL과 HOMEPAGE_URL은 https URL이어야 합니다"
  exit 64
}
url_path=${url%%\?*}
expected_pkg_name="Runtinue-${version}.pkg"
[[ "${url_path:t}" == "${expected_pkg_name}" ]] || {
  print -u2 "RELEASE_URL 파일명은 ${expected_pkg_name}이어야 합니다"
  exit 64
}
"${script_dir}/verify-release.sh" "${pkg}"
sha256=$(/usr/bin/shasum -a 256 "${pkg}" | /usr/bin/awk '{print $1}')
mkdir -p "${output:h}"
/usr/bin/awk \
  -v version="${version}" \
  -v sha256="${sha256}" \
  -v url="${url}" \
  -v homepage="${homepage}" \
  '{ gsub("@@VERSION@@", version); gsub("@@SHA256@@", sha256); gsub("@@URL@@", url); gsub("@@HOMEPAGE@@", homepage); print }' \
  "${project_root}/Casks/runtinue.rb.template" > "${output}"

print "고정 checksum Cask 생성: ${output}"
