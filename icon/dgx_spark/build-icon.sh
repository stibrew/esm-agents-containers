#!/usr/bin/env bash
# Build ICON for a hybrid (GPU atmosphere + CPU ocean) job inside the GB10
# container, following the same steps as the Dolpung setup script:
#
#   1. get a source tree with its submodules populated
#   2. out-of-source GPU build            -> <env>/build_dir/icon_gpu_<compiler>/bin/icon
#   3. a Python venv with cython/numpy
#   4. out-of-source CPU build, configured with --enable-bundled-python=yac,mtime
#      and a --prefix, which is the only way to be sure YAC and its whole
#      dependency chain were built -fPIC
#                                         -> <env>/build_dir/icon_cpu_<compiler>/bin/icon
#   5. `make install` in that build's externals/yac
#   6. pip install hiopy against the YAC installed in 5
#
# Both builds are full, coupled builds -- neither may have coupling disabled,
# because the two executables talk to each other through YAC at run time.
#
#   build-icon.sh [-d ENV_DIR] [all|source|gpu|cpu|venv|yac|hiopy]
#
# ENV_DIR defaults to <ICON source root>/experiments (see icon_source_root
# below) or to $ICON_ENV_DIR, and is created if missing.
# Everything the build writes lives under it; the source tree is the only thing
# that may live elsewhere.
#
# Env you may want to set:
#   ICON_SRC        source tree (or clone URL). Default: the bind-mounted
#                   /home/icon/icon if that is a git repository, else
#                   https://gitlab.dkrz.de/icon/icon-mpim.git
#   ICON_BRANCH     branch to check out when cloning (default: main)
#   ICON_CONFIG_DIR where gb10.{gpu,cpu}.nvhpc live (default: next to this
#                   script, then $ICON_CONFIG_DIR from the image)
#   BUILD_JOBS      parallel make jobs (default: half the cores, see below)
#   GPU_TARGET      -gpu= value (default: ccnative, i.e. the card in this machine)
#   UNIFIED_MEM     1 to add mem:unified -- see gb10.gpu.nvhpc
#   SKIP_HIOPY      1 to stop after the YAC install
#   SKIP_SOURCE     1 to skip submodule population, so that the gpu and cpu
#                   builds can be run concurrently against an already
#                   populated tree
set -euo pipefail

require() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
require git
require make
require python3

env_dir="${ICON_ENV_DIR:-}"
while getopts ':d:' opt; do
    case "${opt}" in
        d) env_dir="${OPTARG}" ;;
        *) echo "usage: $0 [-d ENV_DIR] [all|source|gpu|cpu|venv|yac|hiopy]" >&2; exit 2 ;;
    esac
done
shift $(( OPTIND - 1 ))
what="${1:-all}"

# Set by the image; defaulted here so the script also works in a shell that has
# not sourced the image's environment.
MPI_ROOT="${MPI_ROOT:-/opt/nvidia/hpc_sdk/current/comm_libs/mpi}"

# setuptools takes its link command from the interpreter's sysconfig, recorded
# when CPython was built -- with gcc -- and it carries -fwrapv, which nvc
# rejects outright ("nvc-Error-Unknown switch: -fwrapv"). Every step that links a
# Python extension needs this: YAC's binding during the CPU build and again
# during `make install`, and hiopy's own extension after that. The configure
# wrappers bake the same override into BUILD_ENV for the parts ICON's own
# makefiles drive; this covers the steps run from here.
export LDSHARED="${MPI_ROOT}/bin/mpicc -shared"

# nvfortran's OpenACC compilation is memory-hungry; on a 20-core/128 GB Spark,
# all-cores make can push it into swap. Half is a reasonable default.
jobs="${BUILD_JOBS:-$(( $(nproc) / 2 ))}"
(( jobs > 0 )) || jobs=1

# The configure wrappers sit next to this script in the source tree and are also
# copied into the image at $ICON_CONFIG_DIR. Prefer the ones next to the script:
# if you are running the checked-out copy, the checked-out wrappers are the ones
# you meant.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${script_dir}/gb10.gpu.nvhpc" ]; then
    config_dir="${script_dir}"
else
    config_dir="${ICON_CONFIG_DIR:-${script_dir}}"
fi
for w in gb10.gpu.nvhpc gb10.cpu.nvhpc; do
    [ -x "${config_dir}/${w}" ] || { echo "missing configure wrapper: ${config_dir}/${w}" >&2; exit 1; }
done

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

env_dir="${env_dir:-$(icon_source_root)/experiments}"

BASE_DIR="$(mkdir -p "${env_dir}" && cd "${env_dir}" && pwd)"
SRC_DIR="${BASE_DIR}/src_code"
BUILD_DIR="${BASE_DIR}/build_dir"
PY_ENV_DIR="${BASE_DIR}/py_env"
INSTALL_DIR="${BASE_DIR}/install"
mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${INSTALL_DIR}"

# Name the build directories after the compiler, as the Dolpung script does, so
# two SDK versions can coexist in one environment.
compiler="nvhpc-$(nvfortran --version 2>/dev/null | sed -n 's/^nvfortran \([0-9.]*\).*/\1/p' | head -1)"
compiler="${compiler%-}"
if [ "${compiler}" = 'nvhpc' ]; then compiler='nvhpc-unknown'; fi
ICON_BUILD_DIR_GPU="${BUILD_DIR}/icon_gpu_${compiler}"
ICON_BUILD_DIR_CPU="${BUILD_DIR}/icon_cpu_${compiler}"

# The canonical https URL of the ICON repository. Submodule URLs in .gitmodules
# are relative to the origin remote, so a clone taken from a local path or from
# ssh has to have its origin rewritten to this before `git submodule update`
# can resolve them anonymously.
ICON_ORIGIN_HTTPS='https://gitlab.dkrz.de/icon/icon.git'

default_src=/home/icon/icon
icon_src="${ICON_SRC:-}"
if [ -z "${icon_src}" ]; then
    if [ -d "${default_src}/.git" ]; then
        icon_src="${default_src}"
    else
        icon_src='https://gitlab.dkrz.de/icon/icon-mpim.git'
    fi
fi

# The submodules ICON needs for the configurations built here. jsbach is in the
# list because --enable-jsbach defaults to yes; art, emvorado, dace, msgwam, hd
# and comin are not, because their --enable- switches default to no.
SUBMODULES=(
    externals/mtime externals/yac externals/tixi externals/cdi
    externals/fortran-support externals/iconmath externals/memman
    externals/kokkos externals/ppm externals/rte-rrtmgp externals/jsbach
    externals/yaxt
)

step_source() {
    if [ -d "${icon_src}/.git" ]; then
        # A local checkout. Build from it in place when it is writable --
        # submodule population writes into it -- and otherwise take a clone.
        if [ -w "${icon_src}" ] && [ -w "${icon_src}/.git" ]; then
            ICON_SRC_DIR="$(cd "${icon_src}" && pwd)"
        else
            echo "== ${icon_src} is not writable; cloning it into ${SRC_DIR}/icon"
            ICON_SRC_DIR="${SRC_DIR}/icon"
            [ -d "${ICON_SRC_DIR}/.git" ] || git clone "${icon_src}" "${ICON_SRC_DIR}"
            # Relative submodule URLs resolve against origin, and a local path
            # is not a usable base for them.
            git -C "${ICON_SRC_DIR}" remote set-url origin "${ICON_ORIGIN_HTTPS}"
        fi
    else
        ICON_SRC_DIR="${SRC_DIR}/icon"
        if [ -d "${ICON_SRC_DIR}/.git" ]; then
            echo "== using existing checkout in ${ICON_SRC_DIR}"
        else
            echo "== cloning ${icon_src} into ${ICON_SRC_DIR}"
            git clone -b "${ICON_BRANCH:-main}" "${icon_src}" "${ICON_SRC_DIR}"
        fi
    fi

    echo "== source: ${ICON_SRC_DIR}"
    [ -x "${ICON_SRC_DIR}/configure" ] || { echo "no ./configure in ${ICON_SRC_DIR}" >&2; exit 1; }

    # The gpu and cpu steps each begin with this one, so that either can be run
    # on its own. That makes them unsafe to run concurrently: two `git submodule
    # update` processes race on the same index. Populate once with
    # `build-icon.sh source`, then set SKIP_SOURCE=1 for both builds.
    if [ "${SKIP_SOURCE:-0}" = 1 ]; then
        echo "== source: submodules assumed populated (SKIP_SOURCE=1)"
        return
    fi

    # gitlab.dkrz.de serves all of these anonymously over https; the ssh URLs
    # the relative paths resolve to need a key the container does not have.
    echo "== populating submodules (this clones ~2 GB the first time)"
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git -C "${ICON_SRC_DIR}" \
        -c url."https://gitlab.dkrz.de/".insteadOf='git@gitlab.dkrz.de:' \
        submodule update --init --recursive "${SUBMODULES[@]}"
}

step_gpu() {
    echo "== gpu: configuring in ${ICON_BUILD_DIR_GPU}"
    mkdir -p "${ICON_BUILD_DIR_GPU}"
    ( cd "${ICON_BUILD_DIR_GPU}" \
      && ICON_DIR="${ICON_SRC_DIR}" "${config_dir}/gb10.gpu.nvhpc" \
      && echo "== gpu: building with ${jobs} jobs" \
      && make -j"${jobs}" )
    echo "== gpu: ${ICON_BUILD_DIR_GPU}/bin/icon"
}

step_venv() {
    if [ ! -x "${PY_ENV_DIR}/bin/python" ]; then
        echo "== creating python environment in ${PY_ENV_DIR}"
        python3 -m venv "${PY_ENV_DIR}"
    fi
    # Dependencies of YAC's Python binding. hiopy does not need the binding --
    # building it is how we make sure YAC and everything under it is -fPIC.
    "${PY_ENV_DIR}/bin/python" -m pip install --quiet --upgrade \
        pip wheel setuptools cython numpy
}

step_cpu() {
    echo "== cpu: configuring in ${ICON_BUILD_DIR_CPU}"
    mkdir -p "${ICON_BUILD_DIR_CPU}"
    ( cd "${ICON_BUILD_DIR_CPU}" \
      && ICON_DIR="${ICON_SRC_DIR}" "${config_dir}/gb10.cpu.nvhpc" \
            --enable-bundled-python=yac,mtime \
            --prefix="${INSTALL_DIR}" \
            PYTHON="${PY_ENV_DIR}/bin/python" \
      && echo "== cpu: building with ${jobs} jobs" \
      && make -j"${jobs}" )
    echo "== cpu: ${ICON_BUILD_DIR_CPU}/bin/icon"
}

step_yac() {
    echo "== installing YAC from the CPU build into ${INSTALL_DIR}"
    make -C "${ICON_BUILD_DIR_CPU}/externals/yac" install
}

step_hiopy() {
    echo "== installing hiopy against ${INSTALL_DIR}"
    PKG_CONFIG_PATH="${INSTALL_DIR}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    CC="${MPI_ROOT}/bin/mpicc" \
    CXX="${MPI_ROOT}/bin/mpicxx" \
    "${PY_ENV_DIR}/bin/python" -m pip install --quiet \
        'git+https://gitlab.dkrz.de/dkrz-sw/hiopy'

    # hiopy itself does not need these, but the `pre` job mkexp generates for a
    # hiopy experiment does: run/mkexp/defaults/hiopy/init_model_grid.py opens
    # the grid file with xarray to read its cell count, and
    # create_datarequest_config.py parses ISO durations with isodate. Without
    # them the job fails at import, after the run scripts have been generated
    # and before anything has been run.
    "${PY_ENV_DIR}/bin/python" -m pip install --quiet xarray netcdf4 isodate
}

case "${what}" in
    source)              step_source ;;
    gpu)                 step_source; step_gpu ;;
    venv)                step_venv ;;
    cpu)                 step_source; step_venv; step_cpu ;;
    yac)                 step_yac ;;
    hiopy)               step_hiopy ;;
    all)
        step_source
        step_gpu
        step_venv
        step_cpu
        step_yac
        if [ "${SKIP_HIOPY:-0}" != 1 ]; then step_hiopy; fi
        ;;
    *) echo "usage: $0 [-d ENV_DIR] [all|source|gpu|cpu|venv|yac|hiopy]" >&2; exit 2 ;;
esac

echo
echo "done."
if [ -x "${ICON_BUILD_DIR_GPU}/bin/icon" ]; then echo "  atmosphere (GPU) : ${ICON_BUILD_DIR_GPU}/bin/icon"; fi
if [ -x "${ICON_BUILD_DIR_CPU}/bin/icon" ]; then echo "  ocean      (CPU) : ${ICON_BUILD_DIR_CPU}/bin/icon"; fi
if [ -x "${PY_ENV_DIR}/bin/python" ];       then echo "  python env       : ${PY_ENV_DIR}"; fi
echo
echo "Sanity check that the GPU build really carries device code:"
echo "    cuobjdump --list-elf ${ICON_BUILD_DIR_GPU}/bin/icon | head"
echo
echo "Run a hybrid job with:"
echo "    ATM_EXE=${ICON_BUILD_DIR_GPU}/bin/icon OCE_EXE=${ICON_BUILD_DIR_CPU}/bin/icon \\"
echo "        run-hybrid.sh <experiment-dir>"
exit 0
