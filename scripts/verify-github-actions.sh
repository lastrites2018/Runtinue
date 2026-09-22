#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
project_root=$(cd -- "$script_dir/.." && pwd)
checks_workflow="$project_root/.github/workflows/checks.yml"
release_workflow="$project_root/.github/workflows/release-candidate.yml"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

for workflow in "$checks_workflow" "$release_workflow"; do
  [[ -f "$workflow" && ! -L "$workflow" ]] || fail "필수 workflow가 없거나 심볼릭 링크입니다: $workflow"
  grep -Eq '^permissions:[[:space:]]*$' "$workflow" || fail "workflow 최상위 permissions가 없습니다: $workflow"
  grep -Eq '^  contents:[[:space:]]+read[[:space:]]*$' "$workflow" || fail "workflow는 contents: read만 사용해야 합니다: $workflow"
  permission_keys=$(awk '
    /^permissions:[[:space:]]*$/ { inside = 1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && /^  [A-Za-z0-9_-]+:/ { sub(/[[:space:]]+$/, ""); print }
  ' "$workflow")
  [[ "$permission_keys" == '  contents: read' ]] || fail "workflow 권한은 contents: read 하나만 허용합니다: $workflow"
  if grep -Eq '^[[:space:]]+permissions:[[:space:]]*$' "$workflow"; then
    fail "job 또는 step에서 workflow 권한을 확장할 수 없습니다: $workflow"
  fi
  if grep -Eq '^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]+write[[:space:]]*$' "$workflow"; then
    fail "workflow에 write 권한을 둘 수 없습니다: $workflow"
  fi
  if grep -Eq '^[[:space:]]+pull_request_target:[[:space:]]*$' "$workflow"; then
    fail "pull_request_target은 공개 저장소 workflow에서 사용할 수 없습니다: $workflow"
  fi

  while IFS= read -r line; do
    [[ "$line" =~ uses:[[:space:]]*([^[:space:]#]+) ]] || continue
    action=${BASH_REMATCH[1]}
    [[ "$action" == ./* || "$action" == docker://* ]] && continue
    [[ "$action" =~ @[0-9a-f]{40}$ ]] || fail "action ref는 40자리 commit으로 고정해야 합니다: $action"
  done < "$workflow"
done

tracked_workflows=$(git -C "$project_root" ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
expected_workflows=$'.github/workflows/checks.yml\n.github/workflows/release-candidate.yml'
[[ "$tracked_workflows" == "$expected_workflows" ]] || fail "승인되지 않은 GitHub Actions workflow가 추적 중입니다"

if grep -Eq '^[[:space:]]+tags:[[:space:]]*$' "$checks_workflow"; then
  fail "일반 Repository checks는 release 태그에서 중복 실행하지 않습니다"
fi

grep -Eq '^  workflow_dispatch:[[:space:]]*$' "$release_workflow" || fail "release 후보의 수동 실행 trigger가 없습니다"
grep -Eq '^[[:space:]]+tags:[[:space:]]*$' "$release_workflow" || fail "release 후보의 tag trigger가 없습니다"
grep -Fq '      - "v[0-9]*.[0-9]*.[0-9]*"' "$release_workflow" || fail "release tag pattern이 제한되지 않았습니다"
if grep -Eq '^[[:space:]]+inputs:[[:space:]]*$' "$release_workflow"; then
  fail "수동 실행은 별도 tag 문자열이 아니라 workflow의 실제 tag ref를 사용해야 합니다"
fi
grep -Fq 'ref: ${{ github.ref }}' "$release_workflow" || fail "source checkout은 workflow를 시작한 tag ref를 사용해야 합니다"
grep -Fq 'test "${GITHUB_REF_TYPE}" = tag' "$release_workflow" || fail "수동 실행의 tag ref 확인이 없습니다"
grep -Fq 'test "${GITHUB_REF}" = "refs/tags/${GITHUB_REF_NAME}"' "$release_workflow" || \
  fail "승인 ref와 서명 tag의 동일성 확인이 없습니다"
if grep -Eq '^  pull_request(_target)?:[[:space:]]*$' "$release_workflow"; then
  fail "PR은 release secret에 접근할 수 없습니다"
fi
if grep -Fq 'runs-on: ubuntu-' "$release_workflow"; then
  fail "macOS 전용 zsh release 도구를 Ubuntu runner에서 실행할 수 없습니다"
fi
[[ "$(grep -Fc 'runs-on: macos-15' "$release_workflow")" -eq 3 ]] || \
  fail "source, release test와 signing job은 고정 macos-15 runner를 사용해야 합니다"
grep -Fq 'cancel-in-progress: false' "$release_workflow" || fail "공증 중인 후보 실행을 자동 취소할 수 없습니다"
grep -Fq 'environment: release-candidate' "$release_workflow" || fail "보호된 release-candidate environment가 필요합니다"
grep -Fq './scripts/release.sh --candidate-only' "$release_workflow" || fail "workflow는 publish하지 않는 후보 전용 경로를 사용해야 합니다"
if grep -Fq -- '--tests-passed-for' "$release_workflow"; then
  fail "signing job은 release 테스트를 자체 검증 없이 생략할 수 없습니다"
fi
grep -Fq 'TESTED_COMMIT: ${{ needs.release-tests.outputs.tested-commit }}' "$release_workflow" || fail "후보는 성공한 release 테스트 job의 commit에 고정해야 합니다"
grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' "$release_workflow" || \
  fail "후보 artifact action은 Node 24 기반 v7.0.1 commit으로 고정해야 합니다"
grep -Fq 'artifact_root="$RUNNER_TEMP/runtinue-candidate-artifact"' "$release_workflow" || \
  fail "숨김 release 디렉터리 밖의 artifact staging 경로가 없습니다"
[[ "$(grep -Fc '${{ runner.temp }}/runtinue-candidate-artifact/' "$release_workflow")" -eq 3 ]] || \
  fail "검증된 세 후보 파일만 공개 staging 경로에서 업로드해야 합니다"
grep -Fq './scripts/release-manifest.sh verify "$staged_package" "$staged_manifest"' "$release_workflow" || \
  fail "업로드 직전 staging 후보의 manifest 재검증이 없습니다"
grep -Fq '(cd "$artifact_root" && /usr/bin/shasum -a 256 -c "${checksum##*/}")' "$release_workflow" || \
  fail "업로드 직전 staging checksum 재검증이 없습니다"
grep -Fq 'include-hidden-files: false' "$release_workflow" || fail "숨김 artifact 업로드를 허용할 수 없습니다"
grep -Fq 'set +x' "$release_workflow" || fail "secret 사용 단계에서 shell xtrace를 명시적으로 꺼야 합니다"
grep -Fq 'security delete-keychain' "$release_workflow" || fail "임시 signing keychain 정리 단계가 없습니다"
grep -Fq '/bin/rm -f -- "$application_p12" "$installer_p12" "$notary_key"' "$release_workflow" || \
  fail "import 뒤 원본 P12/P8 삭제가 없습니다"
[[ "$(grep -Fc -- '-T /usr/bin/codesign -x' "$release_workflow")" -eq 1 ]] || \
  fail "application signing 개인키는 비추출 상태로 가져와야 합니다"
[[ "$(grep -Fc -- '-T /usr/bin/productbuild -x' "$release_workflow")" -eq 1 ]] || \
  fail "installer signing 개인키는 비추출 상태로 가져와야 합니다"

if grep -Eiq '(^|[[:space:]])gh[[:space:]]+release|actions/create-release|softprops/action-gh-release|release-manifest[.]sh[[:space:]]+publish' "$release_workflow"; then
  fail "후보 workflow는 GitHub Release나 release pointer를 게시할 수 없습니다"
fi

expected_secrets=(
  RUNTINUE_APPLICATION_CERTIFICATE_P12_BASE64
  RUNTINUE_APPLICATION_CERTIFICATE_PASSWORD
  RUNTINUE_INSTALLER_CERTIFICATE_P12_BASE64
  RUNTINUE_INSTALLER_CERTIFICATE_PASSWORD
  RUNTINUE_NOTARY_API_KEY_P8_BASE64
  RUNTINUE_NOTARY_KEY_ID
  RUNTINUE_NOTARY_ISSUER_ID
)
secret_count=0
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]+[A-Z0-9_]+:[[:space:]]+\$\{\{[[:space:]]secrets\.([A-Z0-9_]+)[[:space:]]\}\}[[:space:]]*$ ]] || \
    fail "secret은 run script가 아니라 step env에만 전달해야 합니다"
  secret_name=${BASH_REMATCH[1]}
  allowed=NO
  for expected in "${expected_secrets[@]}"; do
    [[ "$secret_name" == "$expected" ]] && allowed=YES
  done
  [[ "$allowed" == YES ]] || fail "승인되지 않은 release secret 참조: $secret_name"
  secret_count=$((secret_count + 1))
done < <(grep -F '${{ secrets.' "$release_workflow" || true)
[[ "$secret_count" -eq "${#expected_secrets[@]}" ]] || fail "release secret 참조 수가 예상과 다릅니다"
for expected in "${expected_secrets[@]}"; do
  [[ "$(grep -Fc "secrets.${expected}" "$release_workflow")" -eq 1 ]] || fail "release secret은 정확히 한 번만 env에 연결해야 합니다: $expected"
done

first_secret_line=$(grep -n -m 1 -F '${{ secrets.' "$release_workflow" | cut -d: -f1)
preflight_line=$(grep -n -m 1 -F 'test "$(./scripts/version.sh --release)" = "$EXPECTED_VERSION"' "$release_workflow" | cut -d: -f1)
delete_credentials_line=$(grep -n -m 1 -F '/bin/rm -f -- "$application_p12" "$installer_p12" "$notary_key"' "$release_workflow" | cut -d: -f1)
release_line=$(grep -n -m 1 -F './scripts/release.sh --candidate-only' "$release_workflow" | cut -d: -f1)
staged_verify_line=$(grep -n -m 1 -F './scripts/release-manifest.sh verify "$staged_package" "$staged_manifest"' "$release_workflow" | cut -d: -f1)
explicit_cleanup_line=$(grep -n -m 1 -E '^[[:space:]]+cleanup[[:space:]]*$' "$release_workflow" | cut -d: -f1)
[[ -n "$first_secret_line" && -n "$preflight_line" && -n "$delete_credentials_line" && -n "$release_line" && \
  "$preflight_line" -lt "$first_secret_line" && "$first_secret_line" -lt "$delete_credentials_line" && \
  "$delete_credentials_line" -lt "$release_line" ]] || \
  fail "저장소 검증, secret 주입, 원본 credential 삭제와 빌드 순서가 안전하지 않습니다"
[[ -n "$staged_verify_line" && -n "$explicit_cleanup_line" && "$staged_verify_line" -lt "$explicit_cleanup_line" ]] || \
  fail "후보 staging 검증 직후 임시 signing keychain을 폐기해야 합니다"
repo_calls_with_raw_secrets=$(sed -n "${first_secret_line},$((delete_credentials_line - 1))p" "$release_workflow" | \
  grep -E '[.]/scripts/' || true)
[[ -z "$repo_calls_with_raw_secrets" ]] || fail "원본 secret이 남은 동안 저장소 스크립트를 실행할 수 없습니다"

printf 'GitHub Actions 권한, trigger, action pin과 release secret 경계 검사 통과\n'
