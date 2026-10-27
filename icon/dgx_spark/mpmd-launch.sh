#!/usr/bin/env bash
# srun --multi-prog, spelled in OpenMPI.
#
# mkexp's hybrid run script ends with
#
#     ${START} --multi-prog icon_mpmd.conf
#
# where ${START} is "<[MPI] command> -n <total ranks>". On Levante that is srun,
# which reads the SLURM multi-prog file directly. There is no SLURM in this
# container, so [MPI] command in mkexp/environments/gb10_hybrid.config points at
# this script instead: it reads the same file and turns it into OpenMPI's own
# MPMD form, one colon-separated application context per contiguous rank block.
#
#     mpirun -np 1 ./run_model_gpu.sh : -np 16 ./run_model_cpu.sh
#
# Rank order is what makes this correct, not just convenient: ICON's master
# namelist gives each component a rank range of MPI_COMM_WORLD, and mkexp
# computes those ranges (see run_gb10_hybrid.tmpl:split_tasks) assuming the
# atmosphere occupies the low ranks. OpenMPI numbers ranks in the order the
# application contexts appear, so the contexts have to be emitted in rank order.
#
#   mpmd-launch.sh -n <ntasks> --multi-prog <file>
#
# Recognised: -n/--ntasks[=]N and --multi-prog[=]FILE. Anything else is passed
# to mpirun untouched, so an environment config can still add mpirun flags.
set -euo pipefail

ntasks=
conf=
passthrough=()

while (( $# )); do
    case "$1" in
        -n|--ntasks)      ntasks="$2"; shift 2 ;;
        -n*)              ntasks="${1#-n}"; shift ;;
        --ntasks=*)       ntasks="${1#--ntasks=}"; shift ;;
        --multi-prog)     conf="$2"; shift 2 ;;
        --multi-prog=*)   conf="${1#--multi-prog=}"; shift ;;
        *)                passthrough+=("$1"); shift ;;
    esac
done

[ -n "${conf}" ] || { echo "mpmd-launch.sh: no --multi-prog file given" >&2; exit 2; }
[ -r "${conf}" ] || { echo "mpmd-launch.sh: cannot read ${conf}" >&2; exit 2; }
[ -n "${ntasks}" ] || { echo "mpmd-launch.sh: no -n <ntasks> given" >&2; exit 2; }

# Expand the multi-prog file into one command per rank, then fold consecutive
# ranks that share a command back into blocks. Doing it per rank rather than per
# line is what keeps a '*' catch-all in the right place even when it is not the
# last line of the file.
mapfile -t -d '' args < <(
    MPMD_CONF="${conf}" MPMD_NTASKS="${ntasks}" python3 - <<'PY'
import os, shlex, sys

conf = os.environ['MPMD_CONF']
ntasks = int(os.environ['MPMD_NTASKS'])

ranks = [None] * ntasks
default = None

with open(conf) as f:
    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        spec, _, command = line.partition(' ')
        command = command.strip()
        if not command:
            sys.exit(f"mpmd-launch.sh: {conf}:{lineno}: no command after rank spec")
        argv = shlex.split(command)
        # A relative program name is relative to the experiment directory the
        # run script cd'd into; mpirun does not guarantee that as the cwd of the
        # launched process, so anchor it here while we still know what it was.
        if argv[0].startswith('./'):
            argv[0] = os.path.abspath(argv[0])
        if spec == '*':
            default = argv
            continue
        for part in spec.split(','):
            if '-' in part:
                lo, hi = part.split('-', 1)
                selected = range(int(lo), int(hi) + 1)
            else:
                selected = [int(part)]
            for rank in selected:
                if not 0 <= rank < ntasks:
                    sys.exit(f"mpmd-launch.sh: {conf}:{lineno}: rank {rank} "
                             f"outside 0-{ntasks - 1}")
                ranks[rank] = argv

if default is not None:
    ranks = [argv if argv is not None else default for argv in ranks]

missing = [i for i, argv in enumerate(ranks) if argv is None]
if missing:
    sys.exit(f"mpmd-launch.sh: {conf}: no command for rank(s) "
             f"{missing[0]}..{missing[-1]}; add a '*' line")

out = []
start = 0
for i in range(1, ntasks + 1):
    if i == ntasks or ranks[i] != ranks[start]:
        if out:
            out.append(':')
        out += ['-np', str(i - start)] + ranks[start]
        start = i

sys.stdout.write('\0'.join(out))
PY
)

(( ${#args[@]} )) || { echo "mpmd-launch.sh: could not expand ${conf}" >&2; exit 2; }

cmd=(mpirun)
[ "$(id -u)" = 0 ] && cmd+=(--allow-run-as-root)
cmd+=("${passthrough[@]}" "${args[@]}")

echo "+ ${cmd[*]}"
exec "${cmd[@]}"
