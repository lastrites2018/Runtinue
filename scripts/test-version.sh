#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
test_root=$(/usr/bin/mktemp -d /tmp/runtinue-version-tests.XXXXXX)
trap '/bin/rm -rf -- "${test_root}"' EXIT
fixture="${test_root}/repository"
/bin/mkdir -p "${fixture}/scripts"
/bin/cp "${project_root}/VERSION" "${fixture}/VERSION"
/bin/cp "${script_dir}/version.sh" "${fixture}/scripts/version.sh"
print '.release/' > "${fixture}/.gitignore"
/usr/bin/git -C "${fixture}" init --quiet
/usr/bin/git -C "${fixture}" config user.name 'Version Fixture'
/usr/bin/git -C "${fixture}" config user.email 'version-test@example.invalid'
/usr/bin/git -C "${fixture}" config commit.gpgsign false
/usr/bin/git -C "${fixture}" config core.hooksPath /dev/null
/usr/bin/git -C "${fixture}" add VERSION .gitignore scripts/version.sh
/usr/bin/git -C "${fixture}" commit --quiet -m 'Version fixture'
version=$(/bin/zsh "${fixture}/scripts/version.sh")

passed=0
expect_exit() {
  local expected=$1
  shift
  local actual=0
  "$@" > "${test_root}/result" 2>&1 || actual=$?
  [[ "${actual}" -eq "${expected}" ]] || {
    print -u2 "버전 검사 예상 ${expected}, 실제 ${actual}: $*"
    /usr/bin/sed -n '1,12p' "${test_root}/result" >&2
    exit 1
  }
  passed=$((passed + 1))
}

expect_exit 0 /bin/zsh "${fixture}/scripts/version.sh"
expect_exit 64 /usr/bin/env VERSION=99.99.99 /bin/zsh "${fixture}/scripts/version.sh"
expect_exit 65 /bin/zsh "${fixture}/scripts/version.sh" --release
/usr/bin/git -C "${fixture}" tag "v${version}"
expect_exit 0 /bin/zsh "${fixture}/scripts/version.sh" --release
print changed >> "${fixture}/scripts/version.sh"
expect_exit 65 /bin/zsh "${fixture}/scripts/version.sh" --release
/bin/cp "${script_dir}/version.sh" "${fixture}/scripts/version.sh"
print 'untracked source' > "${fixture}/new.swift"
expect_exit 65 /bin/zsh "${fixture}/scripts/version.sh" --release
/bin/rm -- "${fixture}/new.swift"
/bin/mkdir -p "${fixture}/.release"
print 'private record' > "${fixture}/.release/record.txt"
expect_exit 0 /bin/zsh "${fixture}/scripts/version.sh" --release
print changed > "${fixture}/new.swift"
/usr/bin/git -C "${fixture}" add new.swift
/usr/bin/git -C "${fixture}" commit --quiet -m 'Different commit'
expect_exit 65 /bin/zsh "${fixture}/scripts/version.sh" --release
printf '0.2.\n2\n' > "${fixture}/VERSION"
expect_exit 64 /bin/zsh "${fixture}/scripts/version.sh"

for entry in build.sh package.sh package-development.sh release.sh generate-cask.sh; do
  /usr/bin/grep -Fq '"${script_dir}/version.sh"' "${script_dir}/${entry}" || {
    print -u2 "VERSION 단일 경로를 사용하지 않음: ${entry}"
    exit 1
  }
done
if /usr/bin/grep -Eq 'VERSION=[0-9]|Runtinue-[0-9]+[.][0-9]+' "${project_root}/README.md"; then
  print -u2 "README 명령에 버전을 고정하지 말고 version.sh를 사용하세요"
  exit 1
fi
if /usr/bin/grep -Eq '현재 (개발 )?버전 [0-9]+([.][0-9]+){2}' "${project_root}/README.md"; then
  print -u2 "README 현재 버전에 숫자를 고정하지 말고 VERSION 파일을 참조하세요"
  exit 1
fi
/usr/bin/grep -Fq '[VERSION](VERSION)' "${project_root}/README.md" || {
  print -u2 "README 현재 버전 안내가 VERSION 파일을 참조하지 않습니다"
  exit 1
}
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${project_root}/Packaging/Runtinue.app.Info.plist")" == VERSION_FROM_BUILD ]] || {
  print -u2 "Info.plist 버전은 빌드 시 VERSION 파일에서 주입해야 합니다"
  exit 1
}
print "버전, 태그와 소스 정합성 검사 ${passed}개 통과"
