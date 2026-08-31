#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
version=${VERSION:-0.1.0}
release_root=${SAFECLAM_RELEASE_ROOT:-${project_root}/.release}
release_root=${release_root:A}
export SAFECLAM_DEVELOPMENT_PACKAGE=YES
export DEVELOPER_ID_APPLICATION=-
"${script_dir}/package.sh"
pkg="${release_root}/SafeClam-${version}-development.pkg"
manifest="${pkg}.manifest.json"
"${script_dir}/verify-development-package.sh" "${pkg}"
"${script_dir}/release-manifest.sh" create "${pkg}" "${manifest}" development
"${script_dir}/release-manifest.sh" publish \
  "${pkg}" "${manifest}" \
  "${project_root}/.release/SafeClam-latest-development.json"
