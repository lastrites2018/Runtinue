#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}

usage() {
  print -u2 "사용법: release-manifest.sh create <SafeClam.pkg> <manifest.json> [development|release] [--rollback]"
  print -u2 "       release-manifest.sh verify <SafeClam.pkg> <manifest.json> [--rollback]"
  print -u2 "       release-manifest.sh publish <SafeClam.pkg> <manifest.json> <pointer.json>"
  exit 64
}

fail() {
  local code=${2:-66}
  print -u2 -- "$1"
  exit "${code}"
}

require_file() {
  [[ -f "$1" ]] || fail "파일을 찾을 수 없음: $1"
}

sha256() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

valid_sha256() {
  [[ "$1" =~ '^[0-9a-fA-F]{64}$' ]]
}

valid_json() {
  /usr/bin/plutil -convert xml1 -o /dev/null -- "$1" >/dev/null 2>&1
}

verify_package_signature() {
  local archive=$1 archive_kind=$2 signature_status=$3 signature_output
  if [[ "${archive_kind}" == development ]]; then
    signature_output=$(/usr/sbin/pkgutil --check-signature "${archive}" 2>&1 || true)
    print -r -- "${signature_output}" | /usr/bin/grep -q "Status: no signature" || \
      fail "development 패키지가 unsigned 상태가 아님" 65
    return
  fi
  signature_output=$(/usr/sbin/pkgutil --check-signature "${archive}" 2>&1) || \
    fail "release 패키지의 Installer 서명 검증 실패" 65
  print -r -- "${signature_output}" | /usr/bin/grep -q "Developer ID Installer:" || \
    fail "release 패키지에 Developer ID Installer 서명이 없음" 65
  if [[ "${signature_status}" == signed-notarized ]]; then
    /usr/sbin/spctl -a -t install "${archive}" >/dev/null 2>&1 || \
      fail "release 패키지 Gatekeeper 검증 실패" 65
    /usr/bin/xcrun stapler validate "${archive}" >/dev/null 2>&1 || \
      fail "release 패키지 staple 검증 실패" 65
  fi
}

manifest_value() {
  local key=$1
  local manifest=$2
  /usr/bin/plutil -extract "${key}" raw "${manifest}" 2>/dev/null
}

expand_package() {
  local pkg=$1
  local work_root=$2
  /usr/sbin/pkgutil --expand-full "${pkg}" "${work_root}/expanded" >/dev/null

  local package_dirs=("${work_root}/expanded"/*.pkg(N/))
  [[ ${#package_dirs[@]} -eq 1 ]] || fail "패키지에서 단일 component를 찾지 못함"

  payload_root="${package_dirs[1]}/Payload"
  package_info="${package_dirs[1]}/PackageInfo"
  package_scripts="${package_dirs[1]}/Scripts"
  [[ -d "${payload_root}" && -f "${package_info}" && -d "${package_scripts}" ]] || \
    fail "패키지 component 구조가 올바르지 않음"
  local identifier
  identifier=$(/usr/bin/sed -n 's/^<pkg-info[^>]* identifier="\([^"]*\)".*/\1/p' "${package_info}")
  [[ "${identifier}" == com.example.safeclam.pkg ]] || fail "패키지 identifier 불일치" 65
}

package_version() {
  local value
  value=$(/usr/bin/sed -n 's/^<pkg-info[^>]* version="\([^"]*\)".*/\1/p' "${package_info}" | /usr/bin/sed -n '1p')
  [[ "${value}" =~ '^[0-9]+([.][0-9]+){1,3}$' ]] || fail "패키지 version을 확인할 수 없음"
  print -r -- "${value}"
}

kind_for() {
  local requested=${1:-}
  if [[ -n "${requested}" ]]; then
    [[ "${requested}" == development || "${requested}" == release ]] || \
      fail "패키지 종류는 development 또는 release여야 함" 64
    print -r -- "${requested}"
    return
  fi

  if [[ "${pkg:t}" == *-development.pkg ]]; then
    print -r -- development
  else
    print -r -- release
  fi
}

add_string() {
  local plist=$1
  local key=$2
  local value=$3
  /usr/bin/plutil -insert "${key}" -string "${value}" "${plist}"
}

add_artifact() {
  local plist=$1
  local key=$2
  local payload_path=$3
  local installed_path=$4
  local payload_file="${payload_root}/${payload_path}"
  require_file "${payload_file}"
  add_string "${plist}" "artifacts.${key}.payloadPath" "${payload_path}"
  add_string "${plist}" "artifacts.${key}.installedPath" "${installed_path}"
  add_string "${plist}" "artifacts.${key}.sha256" "$(sha256 "${payload_file}")"
}

add_requirement() {
  local plist=$1
  local key=$2
  local payload_path=$3
  local installed_path=$4
  local payload_file="${payload_root}/${payload_path}"
  require_file "${payload_file}"
  add_string "${plist}" "requirements.${key}.payloadPath" "${payload_path}"
  add_string "${plist}" "requirements.${key}.installedPath" "${installed_path}"
  add_string "${plist}" "requirements.${key}.sha256" "$(sha256 "${payload_file}")"
}

add_script() {
  local plist=$1
  local key=$2
  local script_path=$3
  local script_file="${package_scripts}/${script_path}"
  require_file "${script_file}"
  add_string "${plist}" "packageScripts.${key}.path" "${script_path}"
  add_string "${plist}" "packageScripts.${key}.sha256" "$(sha256 "${script_file}")"
}

create_manifest() {
  pkg=$1
  manifest=$2
  requested_kind=${3:-}
  rollback_mode=${4:-NO}
  require_file "${pkg}"
  [[ -n "${manifest}" ]] || usage
  kind_value=$(kind_for "${requested_kind}")
  [[ "${rollback_mode}" == NO || "${rollback_mode}" == --rollback ]] || usage
  local checked_signature
  if [[ "${kind_value}" == development ]]; then
    checked_signature=unsigned-development
  elif [[ "${SAFECLAM_NOTARIZATION_VERIFIED:-NO}" == YES ]]; then
    checked_signature=signed-notarized
  else
    checked_signature=signed-installer-not-notarized
  fi
  verify_package_signature "${pkg}" "${kind_value}" "${checked_signature}"

  # 생성은 이미 검증된 payload에서만 진행한다. release 서명과 notarization은
  # release.sh가 별도로 검증하며, 이 sidecar는 그것을 자동으로 주장하지 않는다.
  if [[ "${rollback_mode}" == --rollback ]]; then
    if [[ "${kind_value}" == development ]]; then
      signature_output=$(/usr/sbin/pkgutil --check-signature "${pkg}" 2>&1 || true)
      print -r -- "${signature_output}" | /usr/bin/grep -q "Status: no signature" || \
        fail "rollback development 패키지가 unsigned 상태가 아님" 65
    fi
    SAFECLAM_SKIP_SOURCE_COMPARISON=YES \
      "${script_dir}/verify-package-payload.sh" "${pkg}" >/dev/null
  elif [[ "${kind_value}" == development ]]; then
    "${script_dir}/verify-development-package.sh" "${pkg}" >/dev/null
  else
    "${script_dir}/verify-package-payload.sh" "${pkg}" >/dev/null
  fi

  work_root=$(/usr/bin/mktemp -d /tmp/safeclam-release-manifest.XXXXXX)
  cleanup_create() { /bin/rm -rf -- "${work_root}"; }
  trap cleanup_create EXIT
  expand_package "${pkg}" "${work_root}"

  local version_value package_hash plist tmp
  version_value=$(package_version)
  package_hash=$(sha256 "${pkg}")
  valid_sha256 "${package_hash}" || fail "패키지 SHA-256 계산 결과가 올바르지 않음" 65

  plist="${work_root}/manifest.plist"
  /usr/bin/plutil -create xml1 "${plist}"
  /usr/bin/plutil -insert schemaVersion -integer 1 "${plist}"
  /usr/bin/plutil -insert package -dictionary "${plist}"
  /usr/bin/plutil -insert artifacts -dictionary "${plist}"
  /usr/bin/plutil -insert requirements -dictionary "${plist}"
  /usr/bin/plutil -insert packageScripts -dictionary "${plist}"
  /usr/bin/plutil -insert verification -dictionary "${plist}"
  for manifest_key in \
    safeclam safeclamHook safeclamActivity safeclamHelper safeclamSupervisor safeclamMenubar \
    safeclamAppInfo safeclamAppCodeResources helperPlist supervisorPlist uninstallScript; do
    /usr/bin/plutil -insert "artifacts.${manifest_key}" -dictionary "${plist}"
  done
  for manifest_key in helperSupervisor control activity; do
    /usr/bin/plutil -insert "requirements.${manifest_key}" -dictionary "${plist}"
  done
  for manifest_key in preinstall postinstall uninstall; do
    /usr/bin/plutil -insert "packageScripts.${manifest_key}" -dictionary "${plist}"
  done

  add_string "${plist}" kind "${kind_value}"
  add_string "${plist}" package.identifier "com.example.safeclam.pkg"
  add_string "${plist}" package.version "${version_value}"
  add_string "${plist}" package.sha256 "${package_hash}"
  add_string "${plist}" package.signatureStatus "${checked_signature}"

  add_artifact "${plist}" safeclam \
    "usr/local/bin/safeclam" "/usr/local/bin/safeclam"
  add_artifact "${plist}" safeclamHook \
    "usr/local/bin/safeclam-hook" "/usr/local/bin/safeclam-hook"
  add_artifact "${plist}" safeclamActivity \
    "usr/local/bin/safeclam-activity" "/usr/local/bin/safeclam-activity"
  add_artifact "${plist}" safeclamHelper \
    "Library/Application Support/com.example.safeclam/bin/safeclam-helper" \
    "/Library/Application Support/com.example.safeclam/bin/safeclam-helper"
  add_artifact "${plist}" safeclamSupervisor \
    "Library/Application Support/com.example.safeclam/bin/safeclam-supervisor" \
    "/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
  add_artifact "${plist}" safeclamMenubar \
    "Applications/SafeClam.app/Contents/MacOS/safeclam-menubar" \
    "/Applications/SafeClam.app/Contents/MacOS/safeclam-menubar"
  add_artifact "${plist}" safeclamAppInfo \
    "Applications/SafeClam.app/Contents/Info.plist" \
    "/Applications/SafeClam.app/Contents/Info.plist"
  add_artifact "${plist}" safeclamAppCodeResources \
    "Applications/SafeClam.app/Contents/_CodeSignature/CodeResources" \
    "/Applications/SafeClam.app/Contents/_CodeSignature/CodeResources"
  add_artifact "${plist}" helperPlist \
    "Library/LaunchDaemons/com.example.safeclam.helper.plist" \
    "/Library/LaunchDaemons/com.example.safeclam.helper.plist"
  add_artifact "${plist}" supervisorPlist \
    "Library/LaunchAgents/com.example.safeclam.supervisor.plist" \
    "/Library/LaunchAgents/com.example.safeclam.supervisor.plist"
  add_artifact "${plist}" uninstallScript \
    "Library/Application Support/com.example.safeclam/uninstall-safeclam" \
    "/Library/Application Support/com.example.safeclam/uninstall-safeclam"
  add_string "${plist}" buildID \
    "$(sha256 "${payload_root}/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor")"

  add_requirement "${plist}" helperSupervisor \
    "Library/Application Support/com.example.safeclam/helper/supervisor.requirement" \
    "/Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
  add_requirement "${plist}" control \
    "Library/Application Support/com.example.safeclam/supervisor/control.requirement" \
    "/Library/Application Support/com.example.safeclam/supervisor/control.requirement"
  add_requirement "${plist}" activity \
    "Library/Application Support/com.example.safeclam/supervisor/activity.requirement" \
    "/Library/Application Support/com.example.safeclam/supervisor/activity.requirement"

  add_script "${plist}" preinstall preinstall
  add_script "${plist}" postinstall postinstall
  add_script "${plist}" uninstall \
    "../Payload/Library/Application Support/com.example.safeclam/uninstall-safeclam"

  add_string "${plist}" verification.payload "passed"
  add_string "${plist}" verification.archiveHash "sha256"
  if [[ "${rollback_mode}" == --rollback ]]; then
    add_string "${plist}" verification.sourceComparison "skipped-rollback-manifest"
  else
    add_string "${plist}" verification.sourceComparison "passed"
  fi

  /usr/bin/plutil -convert json -r -o "${work_root}/manifest.json" "${plist}"
  valid_json "${work_root}/manifest.json" || fail "생성된 manifest JSON이 올바르지 않음" 65

  /bin/mkdir -p "${manifest:h}"
  tmp=$(/usr/bin/mktemp "${manifest}.tmp.XXXXXX")
  /usr/bin/ditto "${work_root}/manifest.json" "${tmp}"
  if [[ -e "${manifest}" || -L "${manifest}" ]]; then
    /usr/bin/cmp -s "${tmp}" "${manifest}" || fail "기존 manifest가 달라 덮어쓰지 않음: ${manifest}" 73
    /bin/rm -f -- "${tmp}"
  else
    /bin/mv -- "${tmp}" "${manifest}"
  fi
  trap - EXIT
  cleanup_create
  print "release manifest 생성 또는 기존 동일 manifest 확인: ${manifest}"
}

verify_hash_field() {
  local manifest=$1
  local key=$2
  local expected actual
  expected=$(manifest_value "${key}.sha256" "${manifest}") || fail "manifest 필드 누락: ${key}.sha256" 65
  valid_sha256 "${expected}" || fail "manifest SHA-256 형식 오류: ${key}" 65
  require_file "${3}"
  actual=$(sha256 "${3}")
  [[ "${actual:l}" == "${expected:l}" ]] || \
    fail "해시 불일치: ${key}" 65
}

verify_manifest() {
  pkg=$1
  manifest=$2
  rollback=${3:-NO}
  require_file "${pkg}"
  require_file "${manifest}"
  valid_json "${manifest}" || fail "manifest JSON이 올바르지 않음" 65

  local schema kind signature_status expected_pkg actual_pkg expected_version actual_version
  schema=$(manifest_value schemaVersion "${manifest}") || fail "manifest schemaVersion 누락" 65
  [[ "${schema}" == 1 ]] || fail "지원하지 않는 manifest schemaVersion: ${schema}" 65
  kind=$(manifest_value kind "${manifest}") || fail "manifest kind 누락" 65
  [[ "${kind}" == development || "${kind}" == release ]] || fail "manifest kind 오류" 65
  signature_status=$(manifest_value package.signatureStatus "${manifest}") || fail "manifest package.signatureStatus 누락" 65
  [[ "$(manifest_value package.identifier "${manifest}")" == com.example.safeclam.pkg ]] || \
    fail "manifest package.identifier 불일치" 65
  if [[ "${kind}" == development ]]; then
    [[ "${signature_status}" == "unsigned-development" ]] || \
      fail "development manifest가 unsigned 패키지를 가리키지 않음" 65
  else
    [[ "${signature_status}" == "signed-notarized" || \
      "${signature_status}" == "signed-installer-not-notarized" ]] || \
      fail "release manifest signatureStatus 오류" 65
  fi

  expected_pkg=$(manifest_value package.sha256 "${manifest}") || fail "manifest package.sha256 누락" 65
  valid_sha256 "${expected_pkg}" || fail "manifest package.sha256 형식 오류" 65
  actual_pkg=$(sha256 "${pkg}")
  [[ "${actual_pkg:l}" == "${expected_pkg:l}" ]] || fail "패키지 SHA-256 불일치" 65
  verify_package_signature "${pkg}" "${kind}" "${signature_status}"

  work_root=$(/usr/bin/mktemp -d /tmp/safeclam-release-manifest-verify.XXXXXX)
  cleanup_verify() { /bin/rm -rf -- "${work_root}"; }
  trap cleanup_verify EXIT
  expand_package "${pkg}" "${work_root}"
  actual_version=$(package_version)
  expected_version=$(manifest_value package.version "${manifest}") || fail "manifest package.version 누락" 65
  [[ "${actual_version}" == "${expected_version}" ]] || fail "패키지 version 불일치" 65

  if [[ "${rollback}" == YES ]]; then
    SAFECLAM_SKIP_SOURCE_COMPARISON=YES "${script_dir}/verify-package-payload.sh" "${pkg}" >/dev/null
  else
    "${script_dir}/verify-package-payload.sh" "${pkg}" >/dev/null
  fi

  local key payload_path file expected_path expected_payload expected_installed expected_build_id supervisor_hash
  local -a artifact_keys=(
    safeclam safeclamHook safeclamActivity safeclamHelper safeclamSupervisor safeclamMenubar
    safeclamAppInfo safeclamAppCodeResources helperPlist supervisorPlist uninstallScript
  )
  local -a artifact_payload_paths=(
    "usr/local/bin/safeclam"
    "usr/local/bin/safeclam-hook"
    "usr/local/bin/safeclam-activity"
    "Library/Application Support/com.example.safeclam/bin/safeclam-helper"
    "Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
    "Applications/SafeClam.app/Contents/MacOS/safeclam-menubar"
    "Applications/SafeClam.app/Contents/Info.plist"
    "Applications/SafeClam.app/Contents/_CodeSignature/CodeResources"
    "Library/LaunchDaemons/com.example.safeclam.helper.plist"
    "Library/LaunchAgents/com.example.safeclam.supervisor.plist"
    "Library/Application Support/com.example.safeclam/uninstall-safeclam"
  )
  local -a artifact_installed_paths=(
    "/usr/local/bin/safeclam"
    "/usr/local/bin/safeclam-hook"
    "/usr/local/bin/safeclam-activity"
    "/Library/Application Support/com.example.safeclam/bin/safeclam-helper"
    "/Library/Application Support/com.example.safeclam/bin/safeclam-supervisor"
    "/Applications/SafeClam.app/Contents/MacOS/safeclam-menubar"
    "/Applications/SafeClam.app/Contents/Info.plist"
    "/Applications/SafeClam.app/Contents/_CodeSignature/CodeResources"
    "/Library/LaunchDaemons/com.example.safeclam.helper.plist"
    "/Library/LaunchAgents/com.example.safeclam.supervisor.plist"
    "/Library/Application Support/com.example.safeclam/uninstall-safeclam"
  )
  expected_build_id=$(manifest_value buildID "${manifest}") || fail "manifest buildID 누락" 65
  valid_sha256 "${expected_build_id}" || fail "manifest buildID 형식 오류" 65
  for key in "${artifact_keys[@]}"; do
    local index=$(( ${artifact_keys[(I)${key}]} ))
    expected_payload="${artifact_payload_paths[index]}"
    expected_installed="${artifact_installed_paths[index]}"
    payload_path=$(manifest_value "artifacts.${key}.payloadPath" "${manifest}") || fail "manifest artifact 경로 누락: ${key}" 65
    expected_path=$(manifest_value "artifacts.${key}.installedPath" "${manifest}") || fail "manifest 설치 경로 누락: ${key}" 65
    [[ "${payload_path}" == "${expected_payload}" ]] || fail "manifest payload 경로 불일치: ${key}" 65
    [[ "${expected_path}" == "${expected_installed}" ]] || fail "manifest 설치 경로 불일치: ${key}" 65
    file="${payload_root}/${payload_path}"
    verify_hash_field "${manifest}" "artifacts.${key}" "${file}"
  done

  local -a requirement_keys=(helperSupervisor control activity)
  local -a requirement_payload_paths=(
    "Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
    "Library/Application Support/com.example.safeclam/supervisor/control.requirement"
    "Library/Application Support/com.example.safeclam/supervisor/activity.requirement"
  )
  local -a requirement_installed_paths=(
    "/Library/Application Support/com.example.safeclam/helper/supervisor.requirement"
    "/Library/Application Support/com.example.safeclam/supervisor/control.requirement"
    "/Library/Application Support/com.example.safeclam/supervisor/activity.requirement"
  )
  for key in "${requirement_keys[@]}"; do
    local index=$(( ${requirement_keys[(I)${key}]} ))
    expected_payload="${requirement_payload_paths[index]}"
    expected_installed="${requirement_installed_paths[index]}"
    payload_path=$(manifest_value "requirements.${key}.payloadPath" "${manifest}") || fail "manifest requirement 경로 누락: ${key}" 65
    expected_path=$(manifest_value "requirements.${key}.installedPath" "${manifest}") || fail "manifest 설치 경로 누락: ${key}" 65
    [[ "${payload_path}" == "${expected_payload}" ]] || fail "manifest requirement payload 경로 불일치: ${key}" 65
    [[ "${expected_path}" == "${expected_installed}" ]] || fail "manifest requirement 설치 경로 불일치: ${key}" 65
    file="${payload_root}/${payload_path}"
    verify_hash_field "${manifest}" "requirements.${key}" "${file}"
  done

  supervisor_hash=$(manifest_value artifacts.safeclamSupervisor.sha256 "${manifest}") || fail "Supervisor hash 누락" 65
  [[ "${supervisor_hash:l}" == "${expected_build_id:l}" ]] || fail "manifest buildID가 Supervisor hash와 다름" 65

  local script_key script_rel expected_script_path
  local -a script_keys=(preinstall postinstall uninstall)
  local -a script_paths=(
    "preinstall"
    "postinstall"
    "../Payload/Library/Application Support/com.example.safeclam/uninstall-safeclam"
  )
  for script_key in "${script_keys[@]}"; do
    local index=$(( ${script_keys[(I)${script_key}]} ))
    expected_script_path="${script_paths[index]}"
    script_rel=$(manifest_value "packageScripts.${script_key}.path" "${manifest}") || fail "manifest 설치 스크립트 경로 누락: ${script_key}" 65
    [[ "${script_rel}" == "${expected_script_path}" ]] || fail "manifest 설치 스크립트 경로 불일치: ${script_key}" 65
    file="${package_scripts}/${script_rel}"
    verify_hash_field "${manifest}" "packageScripts.${script_key}" "${file}"
  done

  trap - EXIT
  cleanup_verify
  if [[ "${rollback}" == YES ]]; then
    print "manifest와 고정 rollback 패키지 검증 통과: ${pkg}"
  else
    print "manifest와 패키지 정적 검증 통과: ${pkg}"
  fi
}

publish_pointer() {
  pkg=$1
  manifest=$2
  pointer=$3
  require_file "${pkg}"
  require_file "${manifest}"
  [[ -n "${pointer}" ]] || usage

  local pointer_kind pointer_signature_status
  verify_manifest "${pkg}" "${manifest}"
  pointer_kind=$(manifest_value kind "${manifest}")
  pointer_signature_status=$(manifest_value package.signatureStatus "${manifest}")
  if [[ "${pointer_kind}" == release && "${pointer_signature_status}" != "signed-notarized" ]]; then
    fail "notarization 검증 전에는 release pointer를 publish하지 않음" 77
  fi

  local work_root pointer_plist tmp manifest_hash package_hash
  work_root=$(/usr/bin/mktemp -d /tmp/safeclam-release-pointer.XXXXXX)
  cleanup_pointer() { /bin/rm -rf -- "${work_root}"; }
  trap cleanup_pointer EXIT
  manifest_hash=$(sha256 "${manifest}")
  package_hash=$(manifest_value package.sha256 "${manifest}")
  pointer_plist="${work_root}/pointer.plist"
  /usr/bin/plutil -create xml1 "${pointer_plist}"
  /usr/bin/plutil -insert schemaVersion -integer 1 "${pointer_plist}"
  /usr/bin/plutil -insert kind -string "$(manifest_value kind "${manifest}")" "${pointer_plist}"
  /usr/bin/plutil -insert packageSha256 -string "${package_hash}" "${pointer_plist}"
  /usr/bin/plutil -insert manifestSha256 -string "${manifest_hash}" "${pointer_plist}"
  /usr/bin/plutil -insert manifestPath -string "${manifest:A}" "${pointer_plist}"
  /usr/bin/plutil -insert packagePath -string "${pkg:A}" "${pointer_plist}"
  /usr/bin/plutil -convert json -r -o "${work_root}/pointer.json" "${pointer_plist}"
  valid_json "${work_root}/pointer.json" || fail "생성된 pointer JSON이 올바르지 않음" 65

  /bin/mkdir -p "${pointer:h}"
  tmp=$(/usr/bin/mktemp "${pointer}.tmp.XXXXXX")
  /usr/bin/ditto "${work_root}/pointer.json" "${tmp}"
  /bin/mv -f -- "${tmp}" "${pointer}"
  trap - EXIT
  cleanup_pointer
  print "검증 통과 후 최신 pointer publish: ${pointer}"
}

[[ $# -ge 1 ]] || usage
command=$1
shift

case "${command}" in
  create)
    [[ $# -ge 2 && $# -le 4 ]] || usage
    create_manifest "$@"
    ;;
  verify)
    [[ $# -ge 2 && $# -le 3 ]] || usage
    if [[ "${3:-}" == "--rollback" ]]; then
      verify_manifest "$1" "$2" YES
    elif [[ $# -eq 2 ]]; then
      verify_manifest "$1" "$2" NO
    else
      usage
    fi
    ;;
  publish)
    [[ $# -eq 3 ]] || usage
    publish_pointer "$@"
    ;;
  *)
    usage
    ;;
esac
