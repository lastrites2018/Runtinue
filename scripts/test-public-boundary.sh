#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
project_root=$(cd -- "$script_dir/.." && pwd)
runtinue_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/runtinue-public-test.XXXXXX")
trap 'rm -rf -- "$runtinue_test_dir"' EXIT
fixture="$runtinue_test_dir/fixture"
mkdir -p "$fixture/scripts" "$fixture/.githooks" \
  "$fixture/.github/workflows" \
  "$fixture/READMEAssets" \
  "$fixture/Packaging/ko.lproj" "$fixture/Packaging/en.lproj" \
  "$fixture/Sources/RuntinueMenuBar/Resources" \
  "$fixture/Tests/RuntinueMenuBarTests" \
  "$fixture/Tests/RuntinueSupervisorSystemTests" \
  "$fixture/Packaging/Runtinue.xcassets/Runtinue.appiconset"
cp "$project_root/.gitignore" "$fixture/.gitignore"
cp "$project_root/VERSION" "$fixture/VERSION"
cp "$script_dir/verify-public-tree.sh" "$fixture/scripts/verify-public-tree.sh"
cp "$script_dir/verify-github-actions.sh" "$fixture/scripts/verify-github-actions.sh"
cp "$project_root/.githooks/pre-commit" "$fixture/.githooks/pre-commit"
cp "$project_root/.githooks/pre-push" "$fixture/.githooks/pre-push"
cp "$project_root/.github/workflows/checks.yml" "$fixture/.github/workflows/checks.yml"
cp "$project_root/.github/workflows/release-candidate.yml" \
  "$fixture/.github/workflows/release-candidate.yml"
chmod +x "$fixture/.githooks/pre-commit" "$fixture/.githooks/pre-push"
printf '# Fixture\n' > "$fixture/README.md"
printf '# Fixture rules\n' > "$fixture/AGENTS.md"
printf '// Fixture\n' > "$fixture/Sources/Fixture.swift"
cp "$project_root/Sources/RuntinueMenuBar/AppInformation.swift" \
  "$fixture/Sources/RuntinueMenuBar/AppInformation.swift"
cp "$project_root/Tests/RuntinueMenuBarTests/MenuBarUsabilityTests.swift" \
  "$fixture/Tests/RuntinueMenuBarTests/MenuBarUsabilityTests.swift"
cp "$project_root/Tests/RuntinueSupervisorSystemTests/TimedDisplayAssertionTests.swift" \
  "$fixture/Tests/RuntinueSupervisorSystemTests/TimedDisplayAssertionTests.swift"
cp "$project_root/READMEAssets/trip-start.png" "$fixture/READMEAssets/trip-start.png"
cp "$project_root/READMEAssets/trip-protected.png" \
  "$fixture/READMEAssets/trip-protected.png"
cp "$project_root/READMEAssets/recovery.png" "$fixture/READMEAssets/recovery.png"
cp "$project_root/Sources/RuntinueMenuBar/Resources/RuntinueTemplate.png" \
  "$fixture/Sources/RuntinueMenuBar/Resources/RuntinueTemplate.png"
cp "$project_root/Packaging/RuntinueIcon.png" "$fixture/Packaging/RuntinueIcon.png"
cp "$project_root/Packaging/ko.lproj/InfoPlist.strings" "$fixture/Packaging/ko.lproj/InfoPlist.strings"
cp "$project_root/Packaging/en.lproj/InfoPlist.strings" "$fixture/Packaging/en.lproj/InfoPlist.strings"
cp "$project_root/Packaging/Runtinue.xcassets/Contents.json" \
  "$fixture/Packaging/Runtinue.xcassets/Contents.json"
cp "$project_root/Packaging/Runtinue.xcassets/Runtinue.appiconset/Contents.json" \
  "$fixture/Packaging/Runtinue.xcassets/Runtinue.appiconset/Contents.json"
git -C "$fixture" init --quiet -b main
git -C "$fixture" config user.name 'Repository Boundary Test'
git -C "$fixture" config user.email 'boundary-test@example.invalid'
git -C "$fixture" config commit.gpgsign false
git -C "$fixture" config core.ignoreCase false
git -C "$fixture" config core.hooksPath .githooks
git -C "$fixture" add \
  .gitignore AGENTS.md README.md READMEAssets VERSION Sources Tests scripts .githooks .github Packaging

passed=0
expect_success() {
  local label=$1
  shift
  if ! "$@" > "$runtinue_test_dir/result" 2>&1; then
    printf '실패: %s\n' "$label" >&2
    sed -n '1,25p' "$runtinue_test_dir/result" >&2
    exit 1
  fi
  passed=$((passed + 1))
}
expect_failure() {
  local label=$1
  shift
  if "$@" > "$runtinue_test_dir/result" 2>&1; then
    printf '차단되어야 하지만 통과했습니다: %s\n' "$label" >&2
    exit 1
  fi
  passed=$((passed + 1))
}
check_fixture() {
  (cd "$fixture" && bash scripts/verify-public-tree.sh "$@")
}
check_workflows() {
  (cd "$fixture" && bash scripts/verify-github-actions.sh)
}

expect_success '허용 파일 스테이징' check_fixture --staged
expect_success 'GitHub Actions 최소 권한과 release secret 경계' check_workflows

release_workflow="$fixture/.github/workflows/release-candidate.yml"
workflow_backup="$runtinue_test_dir/release-candidate.yml"
cp "$release_workflow" "$workflow_backup"
sed -E 's#actions/upload-artifact@[0-9a-f]{40}#actions/upload-artifact@v4#' \
  "$workflow_backup" > "$release_workflow"
expect_failure '가변 action ref 차단' check_workflows
sed 's/contents: read/contents: write/' "$workflow_backup" > "$release_workflow"
expect_failure 'workflow contents write 권한 차단' check_workflows
cp "$workflow_backup" "$release_workflow"
printf '\n  pull_request:\n' >> "$release_workflow"
expect_failure 'PR release secret 경로 차단' check_workflows
sed 's#./scripts/release.sh --candidate-only#./scripts/release.sh#' \
  "$workflow_backup" > "$release_workflow"
expect_failure '자동 publish 가능 경로 차단' check_workflows
cp "$workflow_backup" "$release_workflow"
printf '\n      - run: gh release create v0.0.0\n' >> "$release_workflow"
expect_failure 'GitHub Release 자동 게시 차단' check_workflows
cp "$workflow_backup" "$release_workflow"
sed 's/runs-on: macos-15/runs-on: ubuntu-latest/g' \
  "$workflow_backup" > "$release_workflow"
expect_failure 'zsh 도구의 Ubuntu runner 실행 차단' check_workflows
grep -Fv 'test "${GITHUB_REF_TYPE}" = tag' \
  "$workflow_backup" > "$release_workflow"
expect_failure '수동 실행 tag ref 확인 누락 차단' check_workflows
sed 's#./scripts/release.sh --candidate-only#./scripts/release.sh --candidate-only --tests-passed-for "$TESTED_COMMIT"#' \
  "$workflow_backup" > "$release_workflow"
expect_failure 'signing job release 테스트 생략 차단' check_workflows
sed 's#${{ runner.temp }}/runtinue-candidate-artifact/#.release/candidate/#g' \
  "$workflow_backup" > "$release_workflow"
expect_failure '숨김 release 경로 artifact 업로드 차단' check_workflows
grep -Fv '/bin/rm -f -- "$application_p12" "$installer_p12" "$notary_key"' \
  "$workflow_backup" > "$release_workflow"
expect_failure '원본 signing credential 미삭제 차단' check_workflows
sed 's/-T \/usr\/bin\/codesign -x/-T \/usr\/bin\/codesign/' \
  "$workflow_backup" > "$release_workflow"
expect_failure '추출 가능한 application signing key 차단' check_workflows
sed '/^[[:space:]]*cleanup[[:space:]]*$/d' "$workflow_backup" > "$release_workflow"
expect_failure '후보 검증 뒤 signing keychain 즉시 폐기 누락 차단' check_workflows
cp "$workflow_backup" "$release_workflow"

expect_success '정상 커밋 훅' git -C "$fixture" commit --quiet -m '공개 경계 테스트 기준 커밋'
expect_success '정상 전체 이력' check_fixture --history HEAD
git init --bare --quiet -b main "$runtinue_test_dir/remote.git"
git -C "$fixture" remote add origin "$runtinue_test_dir/remote.git"
expect_success '정상 로컬 푸시 훅' git -C "$fixture" push --quiet origin main

for path in \
  'notes.md' 'Notes.MD' 'nested/README.md' 'nested/AGENTS.md' \
  'docs/notes.swift' 'notes.txt' 'report.pdf' 'report.docx' 'report.rst' \
  'events.jsonl' '.env' 'candidate.hardware.json' \
  '.release/candidate.hardware.json' '.release/result.swift' 'Sources/notes.md' \
  'Sources/session.json' '.github/workflows/private.yml' 'image.png' \
  'READMEAssets/private.png' 'READMEAssets/private.gif' \
  'READMEAssets/session.json' \
  'Packaging/notes.png' 'Sources/RuntinueMenuBar/Resources/private.png' \
  'Packaging/ko.lproj/private.strings' 'Packaging/en.lproj/private.strings' \
  'Packaging/fr.lproj/InfoPlist.strings' \
  'Packaging/Runtinue.xcassets/private.json' \
  'Packaging/Runtinue.xcassets/Runtinue.appiconset/private.json' \
  'secret.p12' 'file with spaces.md' $'file\nwith-newline.md'; do
  mkdir -p "$(dirname -- "$fixture/$path")"
  printf '비공개 테스트 자료\n' > "$fixture/$path"
  expect_success "기본 제외: $path" git -C "$fixture" check-ignore --no-index --quiet -- "$path"
  git -C "$fixture" add -f -- "$path"
  expect_failure "강제 스테이징 차단: $path" check_fixture --staged
  git -C "$fixture" update-index --force-remove -- "$path"
  rm -f -- "$fixture/$path"
done

# 작업 디렉터리의 허용 목록으로 스테이징한 정책을 덮어쓸 수 없습니다.
printf '비공개 테스트 자료\n' > "$fixture/notes.md"
git -C "$fixture" add -f notes.md
printf '\n!notes.md\n' >> "$fixture/.gitignore"
expect_failure '스테이징 정책과 작업 디렉터리 분리' check_fixture --staged
expect_failure '강제 추가 파일의 실제 커밋 차단' git -C "$fixture" commit --quiet -m '차단 대상'
git -C "$fixture" add .gitignore
expect_failure '문서 제외 계약을 푸는 정책 차단' check_fixture --staged
cp "$project_root/.gitignore" "$fixture/.gitignore"
git -C "$fixture" add .gitignore
git -C "$fixture" update-index --force-remove notes.md
rm -f "$fixture/notes.md"

# .gitignore의 예외를 넓혀도 README 화면 이미지는 승인된 세 파일로 제한합니다.
printf '추가 이미지\n' > "$fixture/READMEAssets/extra.jpg"
printf '\n!/READMEAssets/extra.jpg\n' >> "$fixture/.gitignore"
git -C "$fixture" add .gitignore READMEAssets/extra.jpg
expect_failure 'README 화면 이미지 허용 목록 확장 차단' check_fixture --staged
cp "$project_root/.gitignore" "$fixture/.gitignore"
git -C "$fixture" add .gitignore
git -C "$fixture" update-index --force-remove READMEAssets/extra.jpg
rm -f "$fixture/READMEAssets/extra.jpg"

# 대소문자를 구분하는 checkout에서도 READMEAssets의 이름 변형을 허용하지 않습니다.
case_variant_blob=$(printf '대소문자 변형 이미지\n' | git -C "$fixture" hash-object -w --stdin)
printf '\n!/ReadmeAssets/extra.png\n' >> "$fixture/.gitignore"
git -C "$fixture" add .gitignore
git -C "$fixture" update-index --add --cacheinfo \
  "100644,$case_variant_blob,ReadmeAssets/extra.png"
expect_failure 'README 화면 이미지 디렉터리 대소문자 변형 차단' check_fixture --staged
cp "$project_root/.gitignore" "$fixture/.gitignore"
git -C "$fixture" add .gitignore
git -C "$fixture" update-index --force-remove ReadmeAssets/extra.png

ln -s ../README.md "$fixture/Sources/Link.swift"
git -C "$fixture" add Sources/Link.swift
expect_failure '허용 확장자로 만든 심볼릭 링크 차단' check_fixture --staged
git -C "$fixture" update-index --force-remove Sources/Link.swift
rm -f "$fixture/Sources/Link.swift"
git -C "$fixture" update-index --add --cacheinfo "160000,$(git -C "$fixture" rev-parse HEAD),Sources/Module.swift"
expect_failure '허용 확장자로 만든 서브모듈 차단' check_fixture --staged
git -C "$fixture" update-index --force-remove Sources/Module.swift

# 과거 커밋에서 추가하고 현재 커밋에서 삭제해도 전송 전에 차단합니다.
printf '비공개 테스트 자료\n' > "$fixture/notes.md"
git -C "$fixture" add -f notes.md
git -C "$fixture" -c core.hooksPath=/dev/null commit --quiet -m '테스트 전용 금지 이력'
git -C "$fixture" rm --quiet notes.md
git -C "$fixture" -c core.hooksPath=/dev/null commit --quiet -m '현재 트리에서는 삭제'
expect_success '현재 트리만 보면 통과하는 반례' check_fixture --staged
expect_failure '삭제된 문서의 과거 이력 차단' check_fixture --history HEAD
expect_failure '삭제된 문서를 포함한 실제 푸시 차단' git -C "$fixture" push --quiet origin main
local_head=$(git -C "$fixture" rev-parse HEAD)
remote_head=$(git --git-dir="$runtinue_test_dir/remote.git" rev-parse refs/heads/main)
[[ "$local_head" != "$remote_head" ]] || exit 1

blob=$(git -C "$fixture" rev-parse HEAD:Sources/Fixture.swift)
git -C "$fixture" tag blob-fixture "$blob"
expect_failure '트리를 우회하는 blob 태그 차단' git -C "$fixture" push --quiet origin refs/tags/blob-fixture

git clone --quiet --depth 1 "file://$runtinue_test_dir/remote.git" "$runtinue_test_dir/shallow"
[[ "$(git -C "$runtinue_test_dir/shallow" rev-parse --is-shallow-repository)" == true ]] || exit 1
expect_failure '불완전한 이력에서 성공 판정 차단' \
  bash -c 'cd "$1" && bash scripts/verify-public-tree.sh --history HEAD' _ "$runtinue_test_dir/shallow"

printf '공개 파일 경계 회귀 검사 %s개 통과\n' "$passed"
