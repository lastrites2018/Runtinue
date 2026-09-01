#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
version=$(/bin/zsh "${script_dir}/version.sh")
release_root=${RUNTINUE_RELEASE_ROOT:-${project_root}/.release}
release_root=${release_root:A}
export RUNTINUE_DEVELOPMENT_PACKAGE=YES
export DEVELOPER_ID_APPLICATION=-
"${script_dir}/package.sh"
pkg="${release_root}/Runtinue-${version}-development.pkg"
manifest="${pkg}.manifest.json"
"${script_dir}/verify-development-package.sh" "${pkg}"
"${script_dir}/release-manifest.sh" create "${pkg}" "${manifest}" development
"${script_dir}/release-manifest.sh" publish \
  "${pkg}" "${manifest}" \
  "${project_root}/.release/Runtinue-latest-development.json"
