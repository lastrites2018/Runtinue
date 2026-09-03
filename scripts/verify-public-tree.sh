#!/usr/bin/env bash
set -euo pipefail

repository=$(git rev-parse --show-toplevel)
runtinue_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/runtinue-public-check.XXXXXX")
trap 'rm -rf -- "$runtinue_check_dir"' EXIT
mkdir -p "$runtinue_check_dir/policy"

policy_git() {
  git -C "$runtinue_check_dir/policy" --git-dir="$runtinue_check_dir/policy/.git" \
    --work-tree="$runtinue_check_dir/policy" \
    -c core.excludesFile=/dev/null -c core.ignoreCase=false "$@"
}
policy_git init --quiet

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# 허용 목록을 넓혀도 루트 README.md와 AGENTS.md 외 문서와 로컬 자료는 제외합니다.
printf '%s\0' \
  'notes.md' 'README.MD' 'nested/README.md' 'Sources/notes.Md' \
  'docs/private.swift' 'AGENTS.MD' 'agents.md' 'nested/AGENTS.md' \
  '.env' '.release/output.swift' \
  'private.log' 'private.jsonl' 'private.pdf' 'private.txt' \
  'private.docx' 'private.png' 'private.p12' 'Sources/private.json' \
  'READMEAssets/private.png' 'READMEAssets/private.gif' \
  'READMEAssets/session.json' \
  'Packaging/Runtinue.xcassets/private.json' \
  'Packaging/Runtinue.xcassets/Runtinue.appiconset/private.json' \
  > "$runtinue_check_dir/blocked-probes"

check_ignored() {
  local result=0
  policy_git check-ignore --no-index --stdin -z < "$1" > "$2" || result=$?
  [[ "$result" -le 1 ]] || fail '공개 파일 검사에 실패했습니다.'
}

verify_snapshot() {
  local snapshot=$1
  local entry mode path
  if [[ "$snapshot" == index ]]; then
    git -C "$repository" show :.gitignore > "$runtinue_check_dir/policy/.gitignore" \
      || fail '스테이징한 .gitignore가 필요합니다.'
    git -C "$repository" ls-files --stage -z > "$runtinue_check_dir/entries"
  else
    git -C "$repository" show "$snapshot:.gitignore" > "$runtinue_check_dir/policy/.gitignore" \
      || fail '이력에 공개 파일 허용 목록이 없는 커밋이 있습니다.'
    git -C "$repository" ls-tree -r -z "$snapshot" > "$runtinue_check_dir/entries"
  fi

  check_ignored "$runtinue_check_dir/blocked-probes" "$runtinue_check_dir/probe-result"
  cmp -s "$runtinue_check_dir/blocked-probes" "$runtinue_check_dir/probe-result" \
    || fail '루트 README.md와 AGENTS.md 외 문서와 로컬 자료의 제외 규칙을 유지해야 합니다.'

  : > "$runtinue_check_dir/paths"
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}
    path=${entry#*$'\t'}
    case "$mode" in
      100644|100755) ;;
      *)
        printf '심볼릭 링크와 서브모듈은 공개할 수 없습니다: %q\n' "$path" >&2
        exit 1
        ;;
    esac
    printf '%s\0' "$path" >> "$runtinue_check_dir/paths"
  done < "$runtinue_check_dir/entries"

  check_ignored "$runtinue_check_dir/paths" "$runtinue_check_dir/rejected"
  if [[ -s "$runtinue_check_dir/rejected" ]]; then
    printf '공개 허용 목록 밖의 파일이 있습니다:\n' >&2
    while IFS= read -r -d '' path; do
      printf '  %q\n' "$path" >&2
    done < "$runtinue_check_dir/rejected"
    exit 1
  fi
}

verify_history() {
  local ref=$1
  local commit tree
  [[ "$(git -C "$repository" rev-parse --is-shallow-repository)" == false ]] \
    || fail '전체 이력을 검사하려면 shallow clone의 전체 이력을 먼저 가져와야 합니다.'
  commit=$(git -C "$repository" rev-parse --verify --end-of-options "$ref^{commit}") \
    || fail '커밋을 가리키는 브랜치와 태그만 공개할 수 있습니다.'
  git -C "$repository" log --format=%T "$commit" -- > "$runtinue_check_dir/trees"
  LC_ALL=C sort -u "$runtinue_check_dir/trees" > "$runtinue_check_dir/unique-trees"
  while IFS= read -r tree; do
    verify_snapshot "$tree"
  done < "$runtinue_check_dir/unique-trees"
}

case "${1:---staged}" in
  --staged)
    [[ "$#" -le 1 ]] || fail '사용법: verify-public-tree.sh --staged'
    verify_snapshot index
    ;;
  --history)
    [[ "$#" -le 2 ]] || fail '사용법: verify-public-tree.sh --history [HEAD]'
    verify_history "${2:-HEAD}"
    ;;
  --push)
    [[ "$#" -eq 1 ]] || fail '사용법: verify-public-tree.sh --push'
    while read -r local_ref local_oid remote_ref remote_oid; do
      [[ -n "$local_ref" ]] || continue
      [[ "$local_oid" =~ ^0+$ ]] && continue
      verify_history "$local_oid"
    done
    ;;
  *) fail '사용법: verify-public-tree.sh --staged | --history [HEAD] | --push' ;;
esac

printf '공개 파일 경계 검사 통과\n'
