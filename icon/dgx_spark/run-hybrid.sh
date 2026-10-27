#!/usr/bin/env bash
# Launch an ICON hybrid job on a single GB10: atmosphere on the GPU, ocean on
# the CPU, one MPMD job, coupled through YAC.
#
#   run-hybrid.sh /path/to/experiment/dir
#
# The two executables come from the two out-of-source builds build-icon.sh
# makes; each is called bin/icon inside its own build directory, exactly as on
# Dolpung, where the experiment config names
# ${ICON_BUILD_DIR_GPU}/bin/icon for the atmosphere and
# ${ICON_BUILD_DIR_CPU}/bin/icon for the ocean.
#
# Env:
#   ICON_ENV_DIR the environment build-icon.sh created (default:
#                <ICON source root>/experiments);
#                used to locate the two executables
#   ATM_EXE      atmosphere executable  (default: the GPU build under ICON_ENV_DIR)
#   OCE_EXE      ocean executable       (default: the CPU build under ICON_ENV_DIR)
#   ATM_RANKS    ranks running ATM_EXE  (default 1 -- there is one GPU)
#   OCE_RANKS    ranks running OCE_EXE  (default: most of the cores)
#   OCE_THREADS  OMP threads per ocean rank   (default 1)
#   HIOPY_RANKS  hiopy output workers         (default 0; see README)
#
# ---------------------------------------------------------------------------
# Why this does not look like the Dolpung run script
# ---------------------------------------------------------------------------
#
# On Dolpung, mkexp emits a SLURM job that uses `srun --multi-prog` with a
# generated icon_mpmd.conf, plus a hostfile and a per-rank wrapper that maps
# rank -> GPU -> NUMA domain -> InfiniBand NIC, because a node there has four
# GH200s, four NUMA domains and four NICs.
#
# A Spark has one GPU, one NUMA domain, no InfiniBand and no scheduler. All of
# that machinery collapses to: give rank 0 the GPU, give the rest cores, and use
# OpenMPI's own MPMD form. Keeping the Dolpung wrapper here would be cargo cult.
set -euo pipefail

expdir="${1:?usage: run-hybrid.sh <experiment-dir>}"
cd "${expdir}"

ATM_RANKS="${ATM_RANKS:-1}"
# Exported, because wrap_oce.sh below reads it in the launched process, not here.
export OCE_THREADS="${OCE_THREADS:-1}"
HIOPY_RANKS="${HIOPY_RANKS:-0}"
cores="$(nproc)"
# Leave a couple of cores for the atmosphere rank's host-side work and for the
# driver's own threads; a fully packed node makes the GPU rank wait on the CPU.
OCE_RANKS="${OCE_RANKS:-$(( (cores - ATM_RANKS - HIOPY_RANKS - 2) / OCE_THREADS ))}"
(( OCE_RANKS > 0 )) || { echo "no cores left for the ocean; lower ATM_RANKS/OCE_THREADS" >&2; exit 1; }

# Locate the two builds the way build-icon.sh names them:
#   <env>/build_dir/icon_{gpu,cpu}_nvhpc-<version>/bin/icon
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

env_dir="${ICON_ENV_DIR:-$(icon_source_root)/experiments}"
newest_build() {
    # shellcheck disable=SC2012  -- names, not metadata, are what we sort on
    ls -d "${env_dir}/build_dir/icon_$1"_* 2>/dev/null | sort | tail -1
}
ATM_EXE="${ATM_EXE:-$(newest_build gpu)/bin/icon}"
OCE_EXE="${OCE_EXE:-$(newest_build cpu)/bin/icon}"
for exe in "${ATM_EXE}" "${OCE_EXE}"; do
    [ -x "${exe}" ] || { echo "missing executable: ${exe} (run build-icon.sh)" >&2; exit 1; }
done

command -v nvidia-smi >/dev/null || { echo "no nvidia-smi: start the container with --gpus all" >&2; exit 1; }
nvidia-smi -L

cat <<EOF

layout on $(hostname) -- ${cores} cores, $(nvidia-smi -L | wc -l) GPU(s)
  atmosphere : ${ATM_RANKS} rank(s)  on the GPU   (${ATM_EXE})
  ocean      : ${OCE_RANKS} rank(s) x ${OCE_THREADS} thread(s) on the CPU  (${OCE_EXE})
  hiopy      : ${HIOPY_RANKS} worker(s)

EOF

# Per-rank wrappers. The atmosphere rank is the only one allowed to see the GPU:
# an ocean rank that opens a CUDA context steals memory from it for nothing.
cat > ./wrap_atm.sh <<'EOF'
#!/usr/bin/env bash
export CUDA_VISIBLE_DEVICES=0
export OMP_NUM_THREADS=1
# Graph capture needs this with current NVHPC; without it the OpenACC runtime is
# set up too late and the capture fails at the first offloaded region.
export NVCOMPILER_ACC_USE_GRAPH=1
exec "$@"
EOF

cat > ./wrap_oce.sh <<'EOF'
#!/usr/bin/env bash
# Empty, not unset: an empty value hides every device, whereas unsetting it
# exposes all of them.
export CUDA_VISIBLE_DEVICES=
# ...and because it hides them, UCX's CUDA transports are genuinely unavailable
# in this process. The image's UCX_TLS names them, which on a rank with no
# visible device produces a "transports 'cuda_copy','cuda_ipc' are not
# available" warning per rank. Narrow the list instead of silencing it.
export UCX_TLS=self,sm
# mpirun's own environment sets UCX_CUDA_* variables; with the CUDA transports
# out of UCX_TLS they are unused, and UCX says so twice per rank.
export UCX_WARN_UNUSED_ENV_VARS=n
export OMP_NUM_THREADS="${OCE_THREADS:-1}"
export ICON_THREADS="${OMP_NUM_THREADS}"
export OMP_WAIT_POLICY=active
exec "$@"
EOF
chmod +x ./wrap_atm.sh ./wrap_oce.sh

# OpenMPI MPMD: colon-separated application contexts sharing one MPI_COMM_WORLD,
# which is what ICON's master namelist rank ranges assume. Rank order matters --
# the atmosphere must come first so it occupies ranks [0, ATM_RANKS).
cmd=(mpirun --allow-run-as-root
     -np "${ATM_RANKS}" ./wrap_atm.sh "${ATM_EXE}"
     : -np "${OCE_RANKS}" ./wrap_oce.sh "${OCE_EXE}")

if (( HIOPY_RANKS > 0 )); then
    [ -x ./run_hiopy.sh ] || { echo "HIOPY_RANKS>0 but ./run_hiopy.sh is missing -- see README" >&2; exit 1; }
    cmd+=(: -np "${HIOPY_RANKS}" ./run_hiopy.sh)
fi

echo "+ ${cmd[*]}"
echo
exec "${cmd[@]}"
