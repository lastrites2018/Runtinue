#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
work_root=$(/usr/bin/mktemp -d /tmp/runtinue-release-tool-tests.XXXXXX)
current_version=$(/bin/zsh "${script_dir}/version.sh")
cleanup() {
  /bin/rm -rf -- "${work_root}"
}
trap cleanup EXIT

expect_exit() {
  local expected=$1
  shift
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "${actual}" -ne "${expected}" ]]; then
    print -u2 "예상 종료 코드 ${expected}, 실제 ${actual}: $*"
    exit 1
  fi
}

fake_pkg="${work_root}/Runtinue-0.2.0.pkg"
/usr/bin/touch "${fake_pkg}"

fixture_root="${work_root}/installed"
fixture_manifest="${work_root}/fixture.manifest.json"
mkdir -p \
  "${fixture_root}/usr/local/bin" \
  "${fixture_root}/Applications/Runtinue.app/Contents/MacOS" \
  "${fixture_root}/Applications/Runtinue.app/Contents/Resources" \
  "${fixture_root}/Applications/Runtinue.app/Contents/_CodeSignature" \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/bin" \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/helper" \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor" \
  "${fixture_root}/Library/LaunchDaemons" \
  "${fixture_root}/Library/LaunchAgents"

fixture_file() {
  local path=$1
  local value=$2
  print -r -- "${value}" > "${path}"
}

fixture_file "${fixture_root}/usr/local/bin/runtinue" runtinue
fixture_file "${fixture_root}/usr/local/bin/runtinue-hook" runtinue-hook
fixture_file "${fixture_root}/usr/local/bin/runtinue-activity" runtinue-activity
fixture_file \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-helper" \
  runtinue-helper
fixture_file \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor" \
  runtinue-supervisor
fixture_file \
  "${fixture_root}/Applications/Runtinue.app/Contents/MacOS/runtinue-menubar" \
  runtinue-menubar
fixture_file "${fixture_root}/Applications/Runtinue.app/Contents/Info.plist" app-info
fixture_file "${fixture_root}/Applications/Runtinue.app/Contents/Resources/RuntinueTemplate.png" menu-icon
fixture_file "${fixture_root}/Applications/Runtinue.app/Contents/Resources/Runtinue.icns" app-icon
fixture_file \
  "${fixture_root}/Applications/Runtinue.app/Contents/_CodeSignature/CodeResources" \
  app-code-resources
fixture_file "${fixture_root}/Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist" helper-plist
fixture_file "${fixture_root}/Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist" supervisor-plist
fixture_file \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/uninstall-runtinue" \
  uninstall-script
fixture_file \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/helper/supervisor.requirement" \
  supervisor-requirement
fixture_file \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/control.requirement" \
  control-requirement
fixture_file \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/activity.requirement" \
  activity-requirement

fixture_hash() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

fixture_plist="${work_root}/fixture.manifest.plist"
/usr/bin/plutil -create xml1 "${fixture_plist}"
/usr/bin/plutil -insert schemaVersion -integer 1 "${fixture_plist}"
/usr/bin/plutil -insert kind -string development "${fixture_plist}"
/usr/bin/plutil -insert package -dictionary "${fixture_plist}"
/usr/bin/plutil -insert package.identifier -string io.github.lastrites2018.runtinue.pkg "${fixture_plist}"
/usr/bin/plutil -insert package.version -string 0.2.0 "${fixture_plist}"
/usr/bin/plutil -insert package.sha256 -string \
  0000000000000000000000000000000000000000000000000000000000000000 "${fixture_plist}"
/usr/bin/plutil -insert artifacts -dictionary "${fixture_plist}"
/usr/bin/plutil -insert requirements -dictionary "${fixture_plist}"
for fixture_key in \
  runtinue runtinueHook runtinueActivity runtinueHelper runtinueSupervisor runtinueMenubar \
  runtinueAppInfo runtinueAppCodeResources runtinueMenuIcon runtinueAppIcon \
  helperPlist supervisorPlist uninstallScript; do
  /usr/bin/plutil -insert "artifacts.${fixture_key}" -dictionary "${fixture_plist}"
done
for fixture_key in helperSupervisor control activity; do
  /usr/bin/plutil -insert "requirements.${fixture_key}" -dictionary "${fixture_plist}"
done

fixture_manifest_entry() {
  local key=$1
  local path=$2
  local relative=${path#"${fixture_root}"}
  local hash
  hash=$(fixture_hash "${path}")
  /usr/bin/plutil -insert "${key}.installedPath" -string "${relative}" "${fixture_plist}"
  /usr/bin/plutil -insert "${key}.sha256" -string "${hash}" "${fixture_plist}"
}

fixture_manifest_entry artifacts.runtinue "${fixture_root}/usr/local/bin/runtinue"
fixture_manifest_entry artifacts.runtinueHook "${fixture_root}/usr/local/bin/runtinue-hook"
fixture_manifest_entry artifacts.runtinueActivity "${fixture_root}/usr/local/bin/runtinue-activity"
fixture_manifest_entry artifacts.runtinueHelper \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-helper"
fixture_manifest_entry artifacts.runtinueSupervisor \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor"
fixture_manifest_entry artifacts.runtinueMenubar \
  "${fixture_root}/Applications/Runtinue.app/Contents/MacOS/runtinue-menubar"
fixture_manifest_entry artifacts.runtinueAppInfo \
  "${fixture_root}/Applications/Runtinue.app/Contents/Info.plist"
fixture_manifest_entry artifacts.runtinueAppCodeResources \
  "${fixture_root}/Applications/Runtinue.app/Contents/_CodeSignature/CodeResources"
fixture_manifest_entry artifacts.runtinueMenuIcon \
  "${fixture_root}/Applications/Runtinue.app/Contents/Resources/RuntinueTemplate.png"
fixture_manifest_entry artifacts.runtinueAppIcon \
  "${fixture_root}/Applications/Runtinue.app/Contents/Resources/Runtinue.icns"
fixture_manifest_entry artifacts.helperPlist \
  "${fixture_root}/Library/LaunchDaemons/io.github.lastrites2018.runtinue.helper.plist"
fixture_manifest_entry artifacts.supervisorPlist \
  "${fixture_root}/Library/LaunchAgents/io.github.lastrites2018.runtinue.supervisor.plist"
fixture_manifest_entry artifacts.uninstallScript \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/uninstall-runtinue"
fixture_manifest_entry requirements.helperSupervisor \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/helper/supervisor.requirement"
fixture_manifest_entry requirements.control \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/control.requirement"
fixture_manifest_entry requirements.activity \
  "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/activity.requirement"
/usr/bin/plutil -insert buildID -string \
  "$(fixture_hash "${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/bin/runtinue-supervisor")" \
  "${fixture_plist}"
/usr/bin/plutil -convert json -r -o "${fixture_manifest}" "${fixture_plist}"

RUNTINUE_INSTALL_ROOT="${fixture_root}" RUNTINUE_INSTALL_FIXTURE=YES \
  expect_exit 0 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
print "설치 정합성 성공 fixture 통과"
for icon_path in \
  "${fixture_root}/Applications/Runtinue.app/Contents/Resources/RuntinueTemplate.png" \
  "${fixture_root}/Applications/Runtinue.app/Contents/Resources/Runtinue.icns"; do
  /bin/mv -- "${icon_path}" "${icon_path}.missing"
  RUNTINUE_INSTALL_ROOT="${fixture_root}" RUNTINUE_INSTALL_FIXTURE=YES \
    expect_exit 66 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
  /bin/mv -- "${icon_path}.missing" "${icon_path}"
  /usr/bin/ditto "${icon_path}" "${icon_path}.original"
  print tamper >> "${icon_path}"
  RUNTINUE_INSTALL_ROOT="${fixture_root}" RUNTINUE_INSTALL_FIXTURE=YES \
    expect_exit 65 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
  /bin/mv -- "${icon_path}.original" "${icon_path}"
done
print "앱과 메뉴바 아이콘 누락 및 변조 차단 fixture 통과"
missing_requirement="${fixture_root}/Library/Application Support/io.github.lastrites2018.runtinue/supervisor/activity.requirement"
/bin/mv -- "${missing_requirement}" "${missing_requirement}.missing"
RUNTINUE_INSTALL_ROOT="${fixture_root}" RUNTINUE_INSTALL_FIXTURE=YES \
  expect_exit 66 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
/bin/mv -- "${missing_requirement}.missing" "${missing_requirement}"
print "설치 파일 누락 실패 fixture 통과"
print tamper >> "${fixture_root}/Applications/Runtinue.app/Contents/MacOS/runtinue-menubar"
RUNTINUE_INSTALL_ROOT="${fixture_root}" RUNTINUE_INSTALL_FIXTURE=YES \
  expect_exit 65 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
print "앱 단독 변조 실패 fixture 통과"
expect_exit 64 "${script_dir}/install-package.sh" "${fake_pkg}" --manifest "${fixture_manifest}"
expect_exit 64 "${script_dir}/rollback-package.sh" "${fake_pkg}" --manifest "${fixture_manifest}"
print "설치와 rollback 예상 SHA 필수 gate 통과"

mkdir -p "${project_root}/.release"
occupied_root=$(/usr/bin/mktemp -d "${project_root}/.release/release-tool-occupied.XXXXXX")
/usr/bin/touch "${occupied_root}/Runtinue-${current_version}-development.pkg"
expect_exit 73 /usr/bin/env \
  RUNTINUE_RELEASE_ROOT="${occupied_root}" \
  RUNTINUE_DEVELOPMENT_PACKAGE=YES \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/package.sh"
/bin/rm -rf -- "${occupied_root}"
print "기존 패키지 보존 gate 통과"

expect_exit 77 /usr/bin/env -u RUNTINUE_ALLOW_POWER_MUTATION \
  "${script_dir}/integration-test.sh"

expect_exit 64 /usr/bin/env \
  RUNTINUE_ALLOW_POWER_MUTATION=YES \
  "${script_dir}/integration-test.sh" --invalid-scenario

expect_exit 64 /usr/bin/env \
  -u RUNTINUE_EXPECTED_MANIFEST -u RUNTINUE_EXPECTED_PKG -u RUNTINUE_EXPECTED_SHA256 \
  RUNTINUE_ALLOW_POWER_MUTATION=YES "${script_dir}/integration-test.sh"
print "실제 전원 검증의 고정 artifact 필수 gate 통과"

expect_exit 64 /usr/bin/env \
  VERSION="0.1/../../bad" \
  RUNTINUE_DEVELOPMENT_PACKAGE=YES \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/package.sh"

expect_exit 64 /usr/bin/env \
  BUILD_NUMBER=0 \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/build.sh"

expect_exit 64 /usr/bin/env \
  RUNTINUE_RELEASE_ROOT="${project_root}/../" \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/build.sh"
expect_exit 64 /usr/bin/env \
  RUNTINUE_RELEASE_ROOT="${project_root}" \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/build.sh"
print "release root 경계와 rm 안전 gate 통과"

expect_exit 64 /usr/bin/env \
  VERSION=0.2.0 \
  RELEASE_URL="http://example.com/Runtinue-0.2.0.pkg" \
  HOMEPAGE_URL="https://example.com/runtinue" \
  PKG_PATH="${fake_pkg}" \
  "${script_dir}/generate-cask.sh"

expect_exit 64 /usr/bin/env \
  VERSION=0.2.0 \
  RELEASE_URL="https://example.com/wrong.pkg" \
  HOMEPAGE_URL="https://example.com/runtinue" \
  PKG_PATH="${fake_pkg}" \
  "${script_dir}/generate-cask.sh"

candidate_pkg=${RUNTINUE_RELEASE_TEST_PKG:-}
candidate_manifest="${candidate_pkg}.manifest.json"
if [[ -f "${candidate_pkg}" && -f "${candidate_manifest}" ]]; then
  candidate_sha=$(/usr/bin/shasum -a 256 -- "${candidate_pkg}" | /usr/bin/awk '{print $1}')
  rollback_manifest="${work_root}/rollback.manifest.json"
  expect_exit 0 "${script_dir}/release-manifest.sh" create \
    "${candidate_pkg}" "${rollback_manifest}" development --rollback
  expect_exit 0 "${script_dir}/release-manifest.sh" verify \
    "${candidate_pkg}" "${rollback_manifest}" --rollback
  expect_exit 0 "${script_dir}/install-package.sh" "${candidate_pkg}" \
    --sha256 "${candidate_sha}" --manifest "${candidate_manifest}"
  expect_exit 77 "${script_dir}/install-package.sh" "${candidate_pkg}" \
    --sha256 "${candidate_sha}" --manifest "${candidate_manifest}" --apply
  expect_exit 77 "${script_dir}/rollback-package.sh" "${candidate_pkg}" \
    --sha256 "${candidate_sha}" --manifest "${candidate_manifest}" --apply
  print "설치와 rollback 읽기 전용 및 opt-in gate 통과"

  forged_manifest="${work_root}/forged-release.manifest.json"
  /usr/bin/ditto "${candidate_manifest}" "${forged_manifest}"
  /usr/bin/plutil -replace kind -string release "${forged_manifest}"
  /usr/bin/plutil -replace package.signatureStatus -string signed-notarized "${forged_manifest}"
  expect_exit 65 "${script_dir}/release-manifest.sh" verify \
    "${candidate_pkg}" "${forged_manifest}"
  print "unsigned 패키지를 공증된 release로 잘못 표기하는 manifest 거부 통과"
else
  print "실제 패키지 기반 설치와 manifest gate: not-run (RUNTINUE_RELEASE_TEST_PKG 필요)"
fi

print "release 입력 gate 테스트 통과"
