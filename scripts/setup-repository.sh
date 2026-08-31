#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repository=$(git -C "$script_dir/.." rev-parse --show-toplevel)
test -f "$repository/.githooks/pre-commit"
test -f "$repository/.githooks/pre-push"
chmod +x "$repository/.githooks/pre-commit" "$repository/.githooks/pre-push"
git -C "$repository" config --local core.hooksPath .githooks
printf '현재 clone에 커밋 전 검사와 전체 이력 푸시 검사를 설정했습니다.\n'
