#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
release_root=${SAFECLAM_RELEASE_ROOT:-"${project_root}/.release"}
distribution_root="${release_root}/distribution"
payload_root="${release_root}/payload"
version=${VERSION:-0.1.0}
development_package=${SAFECLAM_DEVELOPMENT_PACKAGE:-NO}
[[ "${version}" =~ '^[0-9]+([.][0-9]+){1,3}$' ]] || {
  print -u2 "VERSION 형식이 올바르지 않음"
  exit 64
}
if [[ "${development_package}" == "YES" ]]; then
  export DEVELOPER_ID_APPLICATION=${DEVELOPER_ID_APPLICATION:--}
  installer_identity=""
else
  installer_identity=${DEVELOPER_ID_INSTALLER:?DEVELOPER_ID_INSTALLER를 지정해야 합니다}
  [[ "${DEVELOPER_ID_APPLICATION:-}" != "-" ]] || {
    print -u2 "release 패키지는 ad-hoc Application 서명을 허용하지 않습니다"
    exit 64
  }
fi

project_root_abs=${project_root:A}
release_root_abs=${release_root:A}
case "${release_root_abs}" in
  "${project_root_abs}"/*) ;;
  *) print -u2 "SAFECLAM_RELEASE_ROOT는 프로젝트 내부의 하위 경로여야 합니다"; exit 64 ;;
esac
[[ "${release_root_abs}" != "${project_root_abs}" ]] || {
  print -u2 "SAFECLAM_RELEASE_ROOT로 프로젝트 루트를 사용할 수 없습니다"
  exit 64
}
release_root="${release_root_abs}"
distribution_root="${release_root}/distribution"
payload_root="${release_root}/payload"

component_pkg="${release_root}/SafeClam-component-${version}.pkg"
if [[ "${development_package}" == "YES" ]]; then
  final_pkg="${release_root}/SafeClam-${version}-development.pkg"
else
  final_pkg="${release_root}/SafeClam-${version}.pkg"
fi

# release root는 후보별로 고정하고 기존 산출물을 보존한다. 같은 경로에 다른
# 패키지를 덮어쓰면 sidecar의 고정 SHA와 설치 정합성을 추적할 수 없다.
for existing_output in "${component_pkg}" "${final_pkg}"; do
  if [[ -e "${existing_output}" || -L "${existing_output}" ]]; then
    print -u2 "기존 패키지 산출물을 덮어쓰지 않음: ${existing_output}"
    print -u2 "새 SAFECLAM_RELEASE_ROOT를 지정해 별도 후보로 생성하세요"
    exit 73
  fi
done

VERSION="${version}" "${script_dir}/build.sh"

rm -rf -- "${payload_root}"
mkdir -p \
  "${payload_root}/Applications" \
  "${payload_root}/Library/Application Support/com.example.safeclam/bin" \
  "${payload_root}/Library/Application Support/com.example.safeclam/helper" \
  "${payload_root}/Library/Application Support/com.example.safeclam/supervisor" \
  "${payload_root}/Library/LaunchAgents" \
  "${payload_root}/Library/LaunchDaemons" \
  "${payload_root}/Library/Logs/com.example.safeclam" \
  "${payload_root}/usr/local/bin"

/usr/bin/ditto "${distribution_root}/SafeClam.app" "${payload_root}/Applications/SafeClam.app"
/usr/bin/ditto "${distribution_root}/bin/safeclam-helper" \
  "${payload_root}/Library/Application Support/com.example.safeclam/bin/safeclam-helper"
/usr/bin/ditto "${distribution_root}/bin/safeclam-supervisor" \
  "${payload_root}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
/usr/bin/ditto "${distribution_root}/bin/safeclam" "${payload_root}/usr/local/bin/safeclam"
/usr/bin/ditto "${distribution_root}/bin/safeclam-hook" "${payload_root}/usr/local/bin/safeclam-hook"
/usr/bin/ditto "${distribution_root}/bin/safeclam-activity" "${payload_root}/usr/local/bin/safeclam-activity"
/usr/bin/ditto "${script_dir}/uninstall.sh" \
  "${payload_root}/Library/Application Support/com.example.safeclam/uninstall-safeclam"

/usr/bin/ditto "${distribution_root}/requirements/supervisor.requirement" \
  "${payload_root}/Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
/usr/bin/ditto "${distribution_root}/requirements/control.requirement" \
  "${payload_root}/Library/Application Support/com.example.safeclam/supervisor/control.requirement"
/usr/bin/ditto "${distribution_root}/requirements/activity.requirement" \
  "${payload_root}/Library/Application Support/com.example.safeclam/supervisor/activity.requirement"
/usr/bin/ditto "${project_root}/Resources/com.example.safeclam.helper.plist" \
  "${payload_root}/Library/LaunchDaemons/com.example.safeclam.helper.plist"
/usr/bin/ditto "${project_root}/Resources/com.example.safeclam.supervisor.plist" \
  "${payload_root}/Library/LaunchAgents/com.example.safeclam.supervisor.plist"

chmod 0755 \
  "${payload_root}/Library/Application Support/com.example.safeclam/bin/"* \
  "${payload_root}/Library/Application Support/com.example.safeclam/uninstall-safeclam" \
  "${payload_root}/usr/local/bin/"*
chmod 0600 "${payload_root}/Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
chmod 0644 \
  "${payload_root}/Library/Application Support/com.example.safeclam/supervisor/control.requirement" \
  "${payload_root}/Library/Application Support/com.example.safeclam/supervisor/activity.requirement" \
  "${payload_root}/Library/LaunchDaemons/com.example.safeclam.helper.plist" \
  "${payload_root}/Library/LaunchAgents/com.example.safeclam.supervisor.plist"
chmod 0700 "${payload_root}/Library/Application Support/com.example.safeclam/helper"

/usr/bin/pkgbuild \
  --root "${payload_root}" \
  --scripts "${project_root}/Packaging/pkg-scripts" \
  --identifier "com.example.safeclam.pkg" \
  --version "${version}" \
  --install-location / \
  --ownership recommended \
  "${component_pkg}"

if [[ "${development_package}" == "YES" ]]; then
  /usr/bin/productbuild --package "${component_pkg}" "${final_pkg}"
else
  /usr/bin/productbuild \
    --package "${component_pkg}" \
    --sign "${installer_identity}" \
    "${final_pkg}"
fi

if [[ "${development_package}" == "YES" ]]; then
  print "개발 전용 ad-hoc 바이너리와 unsigned 설치 패키지 생성: ${final_pkg}"
else
  print "서명된 설치 패키지 생성: ${final_pkg}"
fi
