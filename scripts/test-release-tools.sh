#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
work_root=$(/usr/bin/mktemp -d /tmp/safeclam-release-tool-tests.XXXXXX)
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

fake_pkg="${work_root}/SafeClam-0.1.0.pkg"
/usr/bin/touch "${fake_pkg}"

fixture_root="${work_root}/installed"
fixture_manifest="${work_root}/fixture.manifest.json"
mkdir -p \
  "${fixture_root}/usr/local/bin" \
  "${fixture_root}/Applications/SafeClam.app/Contents/MacOS" \
  "${fixture_root}/Applications/SafeClam.app/Contents/_CodeSignature" \
  "${fixture_root}/Library/Application Support/com.example.safeclam/bin" \
  "${fixture_root}/Library/Application Support/com.example.safeclam/helper" \
  "${fixture_root}/Library/Application Support/com.example.safeclam/supervisor" \
  "${fixture_root}/Library/LaunchDaemons" \
  "${fixture_root}/Library/LaunchAgents"

fixture_file() {
  local path=$1
  local value=$2
  print -r -- "${value}" > "${path}"
}

fixture_file "${fixture_root}/usr/local/bin/safeclam" safeclam
fixture_file "${fixture_root}/usr/local/bin/safeclam-hook" safeclam-hook
fixture_file "${fixture_root}/usr/local/bin/safeclam-activity" safeclam-activity
fixture_file \
  "${fixture_root}/Library/Application Support/com.example.safeclam/bin/safeclam-helper" \
  safeclam-helper
fixture_file \
  "${fixture_root}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor" \
  safeclam-supervisor
fixture_file \
  "${fixture_root}/Applications/SafeClam.app/Contents/MacOS/safeclam-menubar" \
  safeclam-menubar
fixture_file "${fixture_root}/Applications/SafeClam.app/Contents/Info.plist" app-info
fixture_file \
  "${fixture_root}/Applications/SafeClam.app/Contents/_CodeSignature/CodeResources" \
  app-code-resources
fixture_file "${fixture_root}/Library/LaunchDaemons/com.example.safeclam.helper.plist" helper-plist
fixture_file "${fixture_root}/Library/LaunchAgents/com.example.safeclam.supervisor.plist" supervisor-plist
fixture_file \
  "${fixture_root}/Library/Application Support/com.example.safeclam/uninstall-safeclam" \
  uninstall-script
fixture_file \
  "${fixture_root}/Library/Application Support/com.example.safeclam/helper/supervisor.requirement" \
  supervisor-requirement
fixture_file \
  "${fixture_root}/Library/Application Support/com.example.safeclam/supervisor/control.requirement" \
  control-requirement
fixture_file \
  "${fixture_root}/Library/Application Support/com.example.safeclam/supervisor/activity.requirement" \
  activity-requirement

fixture_hash() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

fixture_plist="${work_root}/fixture.manifest.plist"
/usr/bin/plutil -create xml1 "${fixture_plist}"
/usr/bin/plutil -insert schemaVersion -integer 1 "${fixture_plist}"
/usr/bin/plutil -insert kind -string development "${fixture_plist}"
/usr/bin/plutil -insert package -dictionary "${fixture_plist}"
/usr/bin/plutil -insert package.identifier -string com.example.safeclam.pkg "${fixture_plist}"
/usr/bin/plutil -insert package.version -string 0.1.0 "${fixture_plist}"
/usr/bin/plutil -insert package.sha256 -string \
  0000000000000000000000000000000000000000000000000000000000000000 "${fixture_plist}"
/usr/bin/plutil -insert artifacts -dictionary "${fixture_plist}"
/usr/bin/plutil -insert requirements -dictionary "${fixture_plist}"
for fixture_key in \
  safeclam safeclamHook safeclamActivity safeclamHelper safeclamSupervisor safeclamMenubar \
  safeclamAppInfo safeclamAppCodeResources helperPlist supervisorPlist uninstallScript; do
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

fixture_manifest_entry artifacts.safeclam "${fixture_root}/usr/local/bin/safeclam"
fixture_manifest_entry artifacts.safeclamHook "${fixture_root}/usr/local/bin/safeclam-hook"
fixture_manifest_entry artifacts.safeclamActivity "${fixture_root}/usr/local/bin/safeclam-activity"
fixture_manifest_entry artifacts.safeclamHelper \
  "${fixture_root}/Library/Application Support/com.example.safeclam/bin/safeclam-helper"
fixture_manifest_entry artifacts.safeclamSupervisor \
  "${fixture_root}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
fixture_manifest_entry artifacts.safeclamMenubar \
  "${fixture_root}/Applications/SafeClam.app/Contents/MacOS/safeclam-menubar"
fixture_manifest_entry artifacts.safeclamAppInfo \
  "${fixture_root}/Applications/SafeClam.app/Contents/Info.plist"
fixture_manifest_entry artifacts.safeclamAppCodeResources \
  "${fixture_root}/Applications/SafeClam.app/Contents/_CodeSignature/CodeResources"
fixture_manifest_entry artifacts.helperPlist \
  "${fixture_root}/Library/LaunchDaemons/com.example.safeclam.helper.plist"
fixture_manifest_entry artifacts.supervisorPlist \
  "${fixture_root}/Library/LaunchAgents/com.example.safeclam.supervisor.plist"
fixture_manifest_entry artifacts.uninstallScript \
  "${fixture_root}/Library/Application Support/com.example.safeclam/uninstall-safeclam"
fixture_manifest_entry requirements.helperSupervisor \
  "${fixture_root}/Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
fixture_manifest_entry requirements.control \
  "${fixture_root}/Library/Application Support/com.example.safeclam/supervisor/control.requirement"
fixture_manifest_entry requirements.activity \
  "${fixture_root}/Library/Application Support/com.example.safeclam/supervisor/activity.requirement"
/usr/bin/plutil -insert buildID -string \
  "$(fixture_hash "${fixture_root}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor")" \
  "${fixture_plist}"
/usr/bin/plutil -convert json -r -o "${fixture_manifest}" "${fixture_plist}"

SAFECLAM_INSTALL_ROOT="${fixture_root}" SAFECLAM_INSTALL_FIXTURE=YES \
  expect_exit 0 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
print "설치 정합성 성공 fixture 통과"
missing_requirement="${fixture_root}/Library/Application Support/com.example.safeclam/supervisor/activity.requirement"
/bin/mv -- "${missing_requirement}" "${missing_requirement}.missing"
SAFECLAM_INSTALL_ROOT="${fixture_root}" SAFECLAM_INSTALL_FIXTURE=YES \
  expect_exit 66 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
/bin/mv -- "${missing_requirement}.missing" "${missing_requirement}"
print "설치 파일 누락 실패 fixture 통과"
print tamper >> "${fixture_root}/Applications/SafeClam.app/Contents/MacOS/safeclam-menubar"
SAFECLAM_INSTALL_ROOT="${fixture_root}" SAFECLAM_INSTALL_FIXTURE=YES \
  expect_exit 65 "${script_dir}/verify-installation.sh" "${fixture_manifest}"
print "앱 단독 변조 실패 fixture 통과"
expect_exit 64 "${script_dir}/install-package.sh" "${fake_pkg}" --manifest "${fixture_manifest}"
expect_exit 64 "${script_dir}/rollback-package.sh" "${fake_pkg}" --manifest "${fixture_manifest}"
print "설치와 rollback 예상 SHA 필수 gate 통과"

mkdir -p "${project_root}/.release"
occupied_root=$(/usr/bin/mktemp -d "${project_root}/.release/release-tool-occupied.XXXXXX")
/usr/bin/touch "${occupied_root}/SafeClam-0.1.0-development.pkg"
expect_exit 73 /usr/bin/env \
  SAFECLAM_RELEASE_ROOT="${occupied_root}" \
  SAFECLAM_DEVELOPMENT_PACKAGE=YES \
  DEVELOPER_ID_APPLICATION=- \
  VERSION=0.1.0 \
  "${script_dir}/package.sh"
/bin/rm -rf -- "${occupied_root}"
print "기존 패키지 보존 gate 통과"

expect_exit 77 /usr/bin/env -u SAFECLAM_ALLOW_POWER_MUTATION \
  "${script_dir}/integration-test.sh"

expect_exit 64 /usr/bin/env \
  SAFECLAM_ALLOW_POWER_MUTATION=YES \
  "${script_dir}/integration-test.sh" --invalid-scenario

expect_exit 64 /usr/bin/env \
  -u SAFECLAM_EXPECTED_MANIFEST -u SAFECLAM_EXPECTED_PKG -u SAFECLAM_EXPECTED_SHA256 \
  SAFECLAM_ALLOW_POWER_MUTATION=YES "${script_dir}/integration-test.sh"
print "실제 전원 검증의 고정 artifact 필수 gate 통과"

expect_exit 64 /usr/bin/env \
  VERSION="0.1/../../bad" \
  SAFECLAM_DEVELOPMENT_PACKAGE=YES \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/package.sh"

expect_exit 64 /usr/bin/env \
  BUILD_NUMBER=0 \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/build.sh"

expect_exit 64 /usr/bin/env \
  SAFECLAM_RELEASE_ROOT="${project_root}/../" \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/build.sh"
expect_exit 64 /usr/bin/env \
  SAFECLAM_RELEASE_ROOT="${project_root}" \
  DEVELOPER_ID_APPLICATION=- \
  "${script_dir}/build.sh"
print "release root 경계와 rm 안전 gate 통과"

expect_exit 64 /usr/bin/env \
  VERSION=0.1.0 \
  RELEASE_URL="http://example.com/SafeClam-0.1.0.pkg" \
  HOMEPAGE_URL="https://example.com/safeclam" \
  PKG_PATH="${fake_pkg}" \
  "${script_dir}/generate-cask.sh"

expect_exit 64 /usr/bin/env \
  VERSION=0.1.0 \
  RELEASE_URL="https://example.com/wrong.pkg" \
  HOMEPAGE_URL="https://example.com/safeclam" \
  PKG_PATH="${fake_pkg}" \
  "${script_dir}/generate-cask.sh"

candidate_pkg=${SAFECLAM_RELEASE_TEST_PKG:-}
latest_pointer="${project_root}/.release/SafeClam-latest-development.json"
if [[ -z "${candidate_pkg}" && -f "${latest_pointer}" ]]; then
  candidate_pkg=$(/usr/bin/plutil -extract packagePath raw "${latest_pointer}")
fi
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
  print "실제 패키지 기반 설치와 manifest gate: not-run (SAFECLAM_RELEASE_TEST_PKG 필요)"
fi

print "release 입력 gate 테스트 통과"
