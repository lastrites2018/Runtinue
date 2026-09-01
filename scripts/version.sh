#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
version=$(<"${project_root}/VERSION")
[[ "${version}" =~ '^[0-9]+[.][0-9]+[.][0-9]+$' ]] || {
  print -u2 "VERSION 파일은 major.minor.patch 형식이어야 합니다"
  exit 64
}
[[ -z "${VERSION:-}" || "${VERSION:-}" == "${version}" ]] || {
  print -u2 "VERSION 환경 변수로 저장소 버전을 바꿀 수 없습니다. VERSION 파일을 수정하세요"
  exit 64
}
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --release ) ]] || {
  print -u2 "사용법: version.sh [--release]"
  exit 64
}

if [[ "${1:-}" == --release ]]; then
  commit=$(/usr/bin/git -C "${project_root}" rev-parse --verify HEAD)
  tagged_commit=$(/usr/bin/git -C "${project_root}" rev-parse --verify "refs/tags/v${version}^{commit}" 2>/dev/null) || {
    print -u2 "release에는 현재 commit의 v${version} 태그가 필요합니다"
    exit 65
  }
  [[ "${commit}" == "${tagged_commit}" ]] || {
    print -u2 "release 태그와 현재 commit이 다릅니다"
    exit 65
  }
  /usr/bin/git -C "${project_root}" diff --quiet HEAD -- || {
    print -u2 "release 전에 추적 중인 변경을 커밋해야 합니다"
    exit 65
  }
  [[ -z "$(/usr/bin/git -C "${project_root}" ls-files --others --exclude-standard)" ]] || {
    print -u2 "release 전에 공개 대상의 미추적 파일을 처리해야 합니다"
    exit 65
  }
fi

print -r -- "${version}"
