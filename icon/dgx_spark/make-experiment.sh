#!/usr/bin/env bash
# Generate the run scripts for a GB10 hybrid experiment with mkexp.
#
#   make-experiment.sh [-d ENV_DIR] [-b gpu|cpu] [CONFIG] [key=value ...]
#
# CONFIG defaults to cpl_r2b4_gb10.config next to this script. Extra key=value
# arguments are passed to mkexp and override the config, e.g.
#
#   make-experiment.sh cpl_r2b4_gb10.config FINAL_DATE=2014-01-21
#
# mkexp finds its defaults, types and options through MKEXP_PATH, which has to
# contain the *build* directory's run/ -- that is where configure writes
# SETUP.config, and SETUP.config is where abs_top_srcdir, abs_top_builddir and
# gpu_enabled come from. This script puts its own directory first on that path
# so that ENVIRONMENT = gb10_hybrid resolves to the config and template under
# config/docker/gb10/mkexp/environments/ rather than to anything in the tree.
#
# -b picks which build's SETUP.config to use, and hence what BUILD_DIR means in
# the generated scripts. It is the GPU build by default, matching the
# atmosphere; the two executables are named explicitly in the experiment config
# either way, so this only affects paths derived from BUILD_DIR.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_dir="${ICON_ENV_DIR:-}"
build='gpu'

while getopts ':d:b:' opt; do
    case "${opt}" in
        d) env_dir="${OPTARG}" ;;
        b) build="${OPTARG}" ;;
        *) echo "usage: $0 [-d ENV_DIR] [-b gpu|cpu] [CONFIG] [key=value ...]" >&2; exit 2 ;;
    esac
done
shift $(( OPTIND - 1 ))

# The scratch tree lives at <ICON source root>/experiments: ICON's own
# .gitignore already excludes /experiments, and it is where mkexp puts
# experiments by default, so builds, the venv and the experiment directories
# all end up under one root inside the checkout instead of in $HOME.
#
# Resolution order, because this script is run from two places:
#   1. the checkout it is part of -- config/docker/gb10/<script> -- which is
#      the case when you run it out of the source tree;
#   2. $ICON_SRC, when it names a checkout. The image installs these scripts in
#      /usr/local/bin, where 1. cannot work;
#   3. the conventional bind mount, /home/icon/icon;
#   4. the nearest checkout at or above $PWD.
# -d ENV_DIR and $ICON_ENV_DIR still override the result.
icon_source_root() {
    local d
    d="$(cd "${script_dir}/../../.." 2>/dev/null && pwd)" || d=''
    if [ -n "${d}" ] && [ -f "${d}/configure" ] && [ -d "${d}/run/mkexp" ]; then
        printf '%s\n' "${d}"; return 0
    fi
    if [ -n "${ICON_SRC:-}" ] && [ -f "${ICON_SRC}/configure" ]; then
        ( cd "${ICON_SRC}" && pwd ); return 0
    fi
    if [ -f /home/icon/icon/configure ]; then printf '%s\n' /home/icon/icon; return 0; fi
    d="$(pwd)"
    while [ "${d}" != / ]; do
        if [ -f "${d}/configure" ]; then printf '%s\n' "${d}"; return 0; fi
        d="$(dirname "${d}")"
    done
    echo "cannot locate an ICON source tree; set ICON_ENV_DIR or run from a checkout" >&2
    return 1
}

icon_root="$(icon_source_root)"
env_dir="${env_dir:-${icon_root}/experiments}"

# The mkexp environment and the experiment config live in config/docker/gb10 of
# the source tree. That is this script's own directory when it is run from a
# checkout, but not when it is run from /usr/local/bin, where the image
# installs it -- only the script is copied there, not the config or
# mkexp/environments.
gb10_dir="${script_dir}"
[ -f "${gb10_dir}/mkexp/environments/gb10_hybrid.config" ] ||
    gb10_dir="${icon_root}/config/docker/gb10"
[ -f "${gb10_dir}/mkexp/environments/gb10_hybrid.config" ] || {
    echo "cannot find config/docker/gb10/mkexp/environments in ${icon_root}" >&2
    exit 1
}

config="${1:-${gb10_dir}/cpl_r2b4_gb10.config}"
[ $# -gt 0 ] && shift
[ -r "${config}" ] || { echo "no such config: ${config}" >&2; exit 1; }

# shellcheck disable=SC2012  -- names, not metadata, are what we sort on
build_dir="$(ls -d "${env_dir}/build_dir/icon_${build}"_* 2>/dev/null | sort | tail -1)"
[ -n "${build_dir}" ] || { echo "no ${build} build under ${env_dir}/build_dir (run build-icon.sh)" >&2; exit 1; }
[ -r "${build_dir}/run/SETUP.config" ] || {
    echo "${build_dir}/run/SETUP.config is missing; that build was never configured" >&2
    exit 1
}

src_dir="$(sed -n 's/^abs_top_srcdir *= *//p' "${build_dir}/run/SETUP.config")"
mkexp="${src_dir}/utils/mkexp/mkexp"
[ -x "${mkexp}" ] || { echo "missing ${mkexp}: git submodule update --init utils/mkexp" >&2; exit 1; }

# mkexp's DEFAULT.config interpolates $USER (MODEL_SUBDIR, WORK_ROOT on some
# environments) and a docker exec shell often has no USER set at all.
export USER="${USER:-$(id -un)}"

export MKEXP_PATH="${gb10_dir}:${build_dir}/run"
echo "MKEXP_PATH=${MKEXP_PATH}"
echo "+ ${mkexp} ${config} $*"
echo

# Keep a copy of the input config beside the generated experiments, so the
# experiments root records what produced them. mkexp writes its own fully
# resolved <EXP_ID>.dump into the scripts directory; this is the file you edit.
mkdir -p "${env_dir}"
cp -p "${config}" "${env_dir}/" 2>/dev/null || true

cd "${build_dir}/run"
exec "${mkexp}" "${config}" "$@"
