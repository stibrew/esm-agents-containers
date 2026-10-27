# ICON hybrid runs on a single GB10 Spark, in a container

A build-and-run environment for Dolpung-style **hybrid** jobs — atmosphere on
the GPU, ocean on the CPU, one MPMD job, coupled through YAC — sized for a
single NVIDIA GB10 (Grace Blackwell / DGX Spark).

```
Dockerfile        the image: NVHPC 25.9 + CUDA 13 + ICON's dependencies, aarch64
gb10.gpu.nvhpc    configure wrapper, GPU build   (cf. config/dkrz/dolpung.gpu.nvhpc-25.7)
gb10.cpu.nvhpc    configure wrapper, CPU build   (cf. config/dkrz/dolpung.cpu.nvhpc-25.7)
build-icon.sh     drives the whole Dolpung setup sequence, both builds included
run-hybrid.sh     launches the two binaries as one MPMD job, by hand

make-experiment.sh          generates a run script with mkexp
cpl_r2b4_gb10.config        the experiment: coupled AES R2B4 atm / R2B4 oce
mpmd-launch.sh              srun --multi-prog, spelled in OpenMPI
mkexp/environments/
  gb10_hybrid.config        mkexp environment: one node, one GPU, no scheduler
  run_gb10_hybrid.tmpl      the macros mkexp's hybrid run script calls
```

## Quick start

```bash
docker build -t icon-gb10 \
    --build-arg ICON_UID="$(id -u)" --build-arg ICON_GID="$(id -g)" \
    config/docker/gb10

docker run --rm -it --gpus all \
    -v /path/to/icon:/home/icon/icon \
    -v /path/to/pool:/pool \
    --shm-size=8g \
    icon-gb10

# inside:
build-icon.sh                       # source + gpu + venv + cpu + yac + hiopy
make-experiment.sh                  # generate the run scripts with mkexp
experiments/cpl_r2b4_gb10/scripts/cpl_r2b4_gb10.run_start
```

Everything the build and the runs write goes to `<ICON source root>/experiments`
-- `build_dir`, `py_env`, `install`, `logs`, one directory per mkexp experiment,
and a copy of the experiment config that produced them (`make-experiment.sh`
refreshes it on every run; the file you edit is the one in this directory). ICON's `.gitignore` already excludes `/experiments`, and it is the
location ICON's own documentation gives for mkexp, so the checkout stays clean
without anything landing in `$HOME`. `build-icon.sh -d <dir>`, `$ICON_ENV_DIR`,
and `make-experiment.sh -d <dir>` all move it; the scripts find the source root
themselves, which matters because the image also installs them in
`/usr/local/bin`, where looking three directories up would find `/usr`.

Note that a built environment does not relocate uniformly. The parts that do
move, checked rather than assumed:

- **The two `bin/icon`** are self-contained: nothing under the environment
  directory appears in their `ldd`, and their `RUNPATH` names only system,
  NVHPC and `/opt/netcdf-fortran` paths.
- **The venv** moves with the usual fixup -- rewrite the absolute path in
  `pyvenv.cfg` and in the text files under `bin/`. Its compiled extensions do
  not record it: `coyote` finds `libcoyote.so` through `$ORIGIN`, and YAC is
  linked into it statically (`install/lib` holds `.a` files), so YAC's
  installation is a build-time dependency only.
- **YAC's `.pc` files** need their `prefix=` rewritten, which only matters if
  you go on to build hiopy again.

What does *not* move is the build directory itself: 263 files under the GPU
build record the old absolute path, and `run/SETUP.config` -- which mkexp reads
for `abs_top_builddir` -- names the build directory. A relocated build still
runs but cannot be rebuilt or reconfigured, so move the results and rebuild,
which is under ten minutes for both.

`--build-arg ICON_UID/ICON_GID` matters. The container user has to be able to
write into the bind-mounted source tree, because `git submodule update --init`
has to populate `externals/` there before anything can be configured. If the
uids do not match, `build-icon.sh` falls back to cloning the tree into
`experiments/src_code/icon` and building from that copy — correct, but it means
your edits in the mount are not what gets built.

`--shm-size=8g` matters too: Docker's 64 MB default is well under what UCX's
POSIX shared-memory transport wants, and it fails as a segfault inside
`MPI_Init`, not as an out-of-space error. See "Traps" below for the detail and
for what makes a generated run work without it.

## What `build-icon.sh` does

It is the container equivalent of the Dolpung environment setup script, step for
step:

1. **source** — makes sure a source tree exists and its submodules are
   populated. ICON declares its submodules with URLs *relative to the origin
   remote*, which upstream is `git@gitlab.dkrz.de:…`; a container has no ssh
   key. Every submodule this build needs is readable anonymously over https, so
   the image and the script both set
   `url."https://gitlab.dkrz.de/".insteadOf "git@gitlab.dkrz.de:"`. Without that
   rewrite the very first step fails with `Permission denied (publickey)`.
2. **gpu** — out-of-source build in `experiments/build_dir/icon_gpu_nvhpc-<ver>`
   using `gb10.gpu.nvhpc`. Produces `bin/icon`.
3. **venv** — `experiments/py_env`, with `cython`/`numpy`/`wheel`/`setuptools`.
4. **cpu** — out-of-source build in `experiments/build_dir/icon_cpu_nvhpc-<ver>`
   using `gb10.cpu.nvhpc`, configured with
   `--enable-bundled-python=yac,mtime --prefix=<env>/install PYTHON=<venv>`.
   Building YAC's Python binding is not because anything uses it — hiopy does
   not — but because it is the only way to be sure YAC and its whole dependency
   chain came out `-fPIC`. Produces `bin/icon`.
5. **yac** — `make install` in that build's `externals/yac`, so there is a YAC
   installation with a `.pc` file to link against.
6. **hiopy** — `pip install git+https://gitlab.dkrz.de/dkrz-sw/hiopy` with
   `PKG_CONFIG_PATH` pointing at that installation.

Any single step can be run on its own: `build-icon.sh gpu`, `build-icon.sh cpu`,
`build-icon.sh hiopy`, and so on. `-d <dir>` (or `ICON_ENV_DIR`) picks a
different environment directory; the default is `<ICON source root>/experiments`.

## Why there are two binaries

A hybrid experiment names two separate executables:

```
[[[hybrid]]]
  [[[[atm]]]]  exec = ${ICON_BUILD_DIR_GPU}/bin/icon
  [[[[oce]]]]  exec = ${ICON_BUILD_DIR_CPU}/bin/icon
```

Same source, configured twice — one OpenACC build for the atmosphere, one plain
CPU build for the ocean — launched together in one MPI job and exchanging fields
through YAC. Both are *full* builds and both keep coupling enabled; a build
without it cannot participate. They are told apart by their build directory, not
by their file name, which is why neither is called `icon-gpu`.

## Running a coupled experiment

`cpl_r2b4_gb10.config` is the coupled AES R2B4 atmosphere / R2B4 ocean setup,
run with the atmosphere on the GPU and the ocean on the CPU. It is
`run/mkexp/types/AES/coupled-R02B04L90.config` inlined and then adjusted, so a
diff against that file is a complete list of what this machine costs.

```bash
make-experiment.sh                              # the default config
make-experiment.sh cpl_r2b4_gb10.config FINAL_DATE=2014-01-23   # overrides
```

mkexp writes the scripts under `experiments/<EXP_ID>/scripts`
and the run is started, not submitted, because there is no scheduler:

```bash
experiments/cpl_r2b4_gb10/scripts/cpl_r2b4_gb10.run_start
```

`make-experiment.sh` exists because mkexp needs two things pointed at it.
`MKEXP_PATH` has to contain the *build* directory's `run/` — that is where
`configure` writes `SETUP.config`, which is where `abs_top_srcdir`,
`abs_top_builddir` and `gpu_enabled` come from — and it has to contain this
directory first, so that `ENVIRONMENT = gb10_hybrid` resolves to
`mkexp/environments/gb10_hybrid.config` here rather than to anything in the
tree. It also sets `USER`, which mkexp interpolates and a `docker exec` shell
often does not have.

### The rank layout

17 ranks: one atmosphere rank on the one GPU, 16 ocean ranks on cores, no
dedicated I/O or restart ranks at all. `num_io_procs = 0` makes the worker
ranks write, which is slower and entirely adequate at R2B4; the dolpung config's
6 atmosphere plus 2 ocean I/O ranks do not fit in 20 cores. `run_gb10_hybrid.tmpl`
computes this and refuses to generate a job that asks for more ranks than there
are cores — nothing else would catch it, since oversubscribing is not an error,
just a slow success.

### What replaces srun

mkexp's hybrid run script ends with `${START} --multi-prog icon_mpmd.conf`.
`${START}` is `[MPI] command` plus `-n <total ranks>`, and on Levante that is
`srun`, which reads the SLURM multi-prog file itself. Here `[MPI] command` is
`mpmd-launch.sh`, which reads the same file and emits OpenMPI's colon-separated
MPMD form instead:

```
mpirun -np 1 .../run_model_gpu.sh : -np 16 .../run_model_cpu.sh
```

Rank order is what makes this correct rather than merely convenient: ICON's
master namelist gives each component a range of `MPI_COMM_WORLD`, mkexp computes
those ranges assuming the atmosphere holds the low ranks, and OpenMPI numbers
ranks in the order the application contexts appear.

`run-hybrid.sh` does the same thing by hand, without mkexp, for a bare
smoke test of the two binaries.

### Output through hiopy

`cpl_r2b4_gb10.config` writes its output through hiopy: ICON hands its fields
to YAC and two worker ranks aggregate them into a Zarr store, instead of ICON
writing netCDF itself. That needs three things beyond the model run:

```bash
build-icon.sh yac && build-icon.sh hiopy    # once: YAC install, then hiopy
make-experiment.sh                          # generates the pre job too
experiments/cpl_r2b4_gb10/scripts/cpl_r2b4_gb10.pre --destructive
experiments/cpl_r2b4_gb10/scripts/cpl_r2b4_gb10.run_start
```

The `pre` job has to be re-run with `--destructive` whenever the variable lists
change: it writes the Zarr hierarchy and `hiopy_data_request.json` from the
config, and the workers only fill in what it laid out.

The workers are two more ranks, taken out of the ocean's share rather than
added on top — `run_gb10_hybrid.tmpl` subtracts `nr_of_workers` from
`oce_procs`, so the job stays at 17 ranks and `icon_mpmd.conf` gains a third
block. It also forces `num_io_procs` to zero for both components when hiopy is
configured, which is what `coupled_to_output = true` means: the output goes out
through the coupler, not through ICON's own I/O ranks.

### hiopy_core's variable lists need adjusting

`output/hiopy_core` is written for a DestinE R2B7 configuration, and eleven of
the variables it asks for do not exist, are the wrong shape, or are named
differently in a coupled AES R2B4 run. Each one aborts the run, one per
attempt, in one of three places — ICON's output setup, YAC's field matching, or
YAC's collection-size check — so it is worth knowing the whole list up front;
`cpl_r2b4_gb10.config` documents the corrections inline.

The general lessons, which will apply again to any other experiment type:

- **Get the variable names from the model, not from the source.** AES and
  ICON-Land build most of their names programmatically, so grepping for
  `'clivi'` finds nothing even though the variable exists. Run once with
  `msg_level = 13` and ICON dumps every registered variable
  (`mo_nh_stepping.f90:1010`). The dump happens at the start of the time loop,
  after output setup — so it has to be a run that gets that far, which means
  reverting to working output first.
- **A CF long name is not a variable name.** `hiopy_core` asks for
  `relative_vorticity_on_cells`; the variable is `vor`.
- **Containers are not variables.** `A_tracer_v` is an `lcontainer` with
  `loutput=.FALSE.`; the real variable is the per-tracer reference
  `A_tracer_v_to`. Likewise `qtop`/`qbot` exist only as `qtop_icecl`.
- **Edge variables cannot be output through the coupler.** `mo_output_coupling`
  exposes cell variables; `A_veloc_v` lives on edges.
- **The group's declared shape has to match the field's.** A field
  dimensioned `n_zlev+1` in a 40-level group, or a 3d field in a 2d group,
  fails in YAC with `collection sizes do not match`, not in ICON.
- **`pl::` is added for you.** A group with `is_pressure_level = true` gets the
  prefix `mo_output_coupling.f90:147` uses. `var_names_dict` is only for
  variables whose p-level name differs from their model-level name, like
  `ua -> pl::u`.

## How a Spark differs from a Dolpung node

|  | Dolpung node | GB10 Spark |
|---|---|---|
| GPUs | 4× GH200 | 1× GB10 (cc121) |
| NUMA domains | 4 | 1 |
| Cores | 288 | 20 |
| Network | 4× InfiniBand NIC | none relevant |
| Scheduler | SLURM | none |

Everything the Dolpung run script does with `srun --multi-prog`, a generated
hostfile, and a per-rank *rank → GPU → NUMA → NIC* wrapper collapses on a Spark
to: give rank 0 the GPU, give the rest cores. `run-hybrid.sh` uses OpenMPI's own
MPMD form instead. Carrying the Dolpung wrapper across would be cargo cult — its
`numanode=(0 1 2 3)` and `mlx5_{0..3}` arrays describe hardware that is not here.

Two consequences worth planning for:

**Rank counts.** A Dolpung experiment config assumes hundreds of ranks. Here you
have order ten. Scale the experiment down — resolution, decomposition, output
frequency — or it will not fit, and the failure will look like an obscure
decomposition error rather than "too few ranks".

**`UCX_TLS`.** Dolpung sets transports including `rc_x`/`ud_x`, which are
InfiniBand. On a single Spark those do not exist, and naming them makes UCX fail
to initialise rather than fall back. The image sets
`self,sm,cuda_copy,cuda_ipc`, which is what a one-node job actually uses.

## Traps this configuration already walked into

Worth knowing, because each one costs an hour to rediscover:

**`-gpu=native` is not a thing.** nvfortran 25.9 spells it `ccnative`, and
rejects `native` with a switch listing 80 lines long. `gb10.gpu.nvhpc` defaults
to `GPU_TARGET=ccnative`; set `GPU_TARGET=cc121` to pin it, e.g. when building
in a container started without `--gpus all`.

**`CUDA_HOME` must be the versioned toolkit directory.** The HPC SDK's `cuda/`
directory symlinks only `bin`, `include`, `lib64` and `nvvm` out of `cuda/13.0/`
— it has no `targets/`. CMake's `FindCUDAToolkit` derives the include path of
the imported `CUDA::cudart` target as `<root>/targets/<triple>/include`, so
pointing `CUDAToolkit_ROOT` at `cuda/` makes the CMake-built externals (memman,
fortran-support) fail with *"Imported target CUDA::cudart includes non-existent
path"*. The image sets `CUDA_HOME=…/cuda/13.0`, and the wrapper resolves a
versioned directory itself if it is handed the aggregate one.

**NetCDF-Fortran cannot come from apt.** Fortran `.mod` files are
compiler-specific, so a gfortran-built `libnetcdff` is unreadable by nvfortran.
The image builds it with nvfortran into `/opt/netcdf-fortran`. Everything else,
including the gfortran-built BLAS/LAPACK, links by symbol name and mixes fine.

**`/dev/shm` is 64 MB unless you ask for more, and it fails as a segfault.**
This is what `--shm-size=8g` in the quick start is for. Without it, UCX's POSIX
shared-memory transport runs out of `/dev/shm` while growing its buffer pool
during `MPI_Init` and *segfaults* — `uct_mm_iface_t_init` → `ucs_mpool_grow`,
signal 11, at 17 ranks — rather than reporting a full filesystem. It cannot be
fixed from inside the container: remounting `/dev/shm` needs `CAP_SYS_ADMIN`,
which the container does not have even with `sudo`. What can be fixed from
inside is which shared-memory transport UCX picks:
`mkexp/environments/gb10_hybrid.config` sets `UCX_TLS=self,sysv,…`, and SysV
segments come from the kernel, whose limits here are effectively unbounded. So
a generated run works either way; a hand-run `run-hybrid.sh` still needs the
container started correctly. Check with `df -h /dev/shm` before blaming
anything else.

**`INTERVAL` is also the checkpoint interval, and it has a floor.**
`mo_time_management.f90` refuses a checkpoint interval below 2.5 hours when
`divdamp_order = 24`, which the AES coupled configuration asks for. A one-hour
chunk therefore aborts in `atm_crosscheck` before the first time step. This is
easy to misread as a coupling or namelist problem when all you wanted was a
short test; make the chunk three hours instead.

**`DEFAULT.config`'s output lists ask for variables this configuration does not
allocate.** Falling back on them produces
`mo_derived_variable_handling:init_op: no source variable: tauu_sso` during
output setup. `EXP_OPTIONS = output/coupled_test` is what the dolpung example
for this experiment type uses, and it is the tested combination.

**Submodules are not optional and not anonymous by default.** See step 1 above.

**setuptools links Python extensions with the wrong compiler's flags.** With
`--enable-bundled-python=yac,…` the YAC binding is linked by setuptools, which
takes its link command from the interpreter's `sysconfig` — recorded when
CPython was built, with gcc. It carries `-fwrapv`, and nvc refuses it outright.
Both configure wrappers export `LDSHARED="<mpicc> -shared"` in `BUILD_ENV`, and
`build-icon.sh` exports the same thing for the `make install` and `pip install`
steps it runs itself.

**Four separate pieces of MPI noise, all container-specific.** The image sets
`OPAL_PREFIX` (HPC-X's Open MPI was relocated, so every diagnostic it tries to
print becomes "couldn't open the help file"), `OMPI_MCA_rtc=^hwloc` (memory
binding fails without the capability to mbind, and
`hwloc_base_mem_bind_failure_action=silent` does *not* suppress the resulting
warning), and `OMPI_MCA_coll_hcoll_enable=0` (HCOLL wants an InfiniBand HCA and
complains per rank per communicator without one). The fourth is per-rank and
lives in `run-hybrid.sh`: the ocean wrapper narrows `UCX_TLS` to `self,sm`,
because it hides the GPU from those ranks and the image's default list names
CUDA transports that are then genuinely unavailable.

## Things you will probably want to change

**Unified memory.** GB10 has physically coherent CPU+GPU memory, and
`UNIFIED_MEM=1 build-icon.sh gpu` adds `-gpu=…,mem:unified`, which lets the
compiler drop explicit data movement. That can be the difference between an
OpenACC port running and not running — and it can equally cost performance,
because it hides where the traffic goes. Use it to get something working, then
measure with it off.

**Which components are enabled.** The wrappers deliberately mirror the Dolpung
ones, which means both builds are full builds: atmosphere, ocean, AES, JSBACH,
RTE-RRTMGP. That is more than a given experiment needs and more that can break,
but it is what the reference configuration does, and the hybrid layout depends
on both executables carrying the same coupling. Trim with `--disable-…` on the
`build-icon.sh` command line if you know what your experiment uses.

**Build parallelism.** `BUILD_JOBS` defaults to half the cores. nvfortran's
OpenACC compilation is memory-hungry and `--enable-pgi-inlib` compiles each
Fortran file twice; all 20 cores at once can push a 128 GB Spark into swap.

**Rank split.** `ATM_RANKS` defaults to 1 because there is one GPU. Running more
than one atmosphere rank on a single device is possible but means they share it,
which is rarely what you want without MPS.

## hiopy

`build-icon.sh` installs it as its last step, into `experiments/py_env`, against
the YAC installed from the CPU build — it links YAC's `coyote` library, so it
cannot be installed before that build exists. `SKIP_HIOPY=1` stops before it.

Then write a `run_hiopy.sh` next to your experiment and set `HIOPY_RANKS`;
`run-hybrid.sh` will append it as a third MPMD application context. ICON's own
`run/mkexp/defaults/hiopy/run.tmpl` is the reference for what that wrapper does.

Note hiopy needs `coupled_to_output = true` in the model namelists, and only
supports the proleptic Gregorian calendar.

## Verifying it actually used the GPU

The failure mode to watch for is a job that runs correctly and entirely on the
CPU, reporting success.

```bash
cuobjdump --list-elf experiments/build_dir/icon_gpu_*/bin/icon | head
ldd experiments/build_dir/icon_gpu_*/bin/icon | grep -E 'libcud(art|a)'
```

Keep `-Minfo=accel` in the build output: it is the only place that says which
loops were actually offloaded. A silently un-accelerated loop is the usual
reason a "GPU" run is slower than the CPU one. And watch `nvidia-smi` during a
run — an idle GPU is the answer.

## Status

Built and run in this container, from the source at `icon-2026.04-150-g06536eb7`
with NVHPC 25.9 / CUDA 13.0 on a GB10:

- `bin/icon` from the GPU build, 235 MB, carries `sm_121` device code
  (`cuobjdump --list-elf` lists `icon.2.sm_121.cubin`) and links `libcudart.so.13`.
- `bin/icon` from the CPU build, 157 MB, with no device code.
- YAC installed from the CPU build (`yac-core.pc`, `yac-mci.pc`), and hiopy
  2026.3 installed against it, with `xarray`/`netcdf4`/`isodate` for the `pre`
  job.
- **A coupled AES R2B4/R2B4 experiment has been run**: `cpl_r2b4_gb10`,
  three simulated hours from 2014-01-20, ocean started from the `ler1166`
  parent restart in `/pool`. Both components reported `OK` both times and wrote
  a multifile restart at `20140120T030000Z`. `nvidia-smi` showed 91-95% GPU
  utilisation during the time loop, so the atmosphere was genuinely offloaded
  and not silently running on the host.
  - with ICON's own netCDF output (17 ranks: 1 atm + 16 oce), files in the
    chunk's work directory;
  - **with hiopy** (17 ranks: 1 atm + 14 oce + 2 workers), writing
    `outdata/cpl_r2b4_gb10.zarr` — 125 MB, 198 arrays over five groups
    (`PT1H_mean_atm`, `PT1H_point_atm`, `PT1H_mean_ocean`, `PT3H_mean_atm`,
    `PT3H_mean_ocean`), three hourly steps and one three-hourly mean, on the
    model grids (20480 atmosphere cells, 15105 ocean cells, 25 pressure
    levels). Spot-checked physical: `temp` 187-314 K, `ua` +/-166 m/s, `xo3`
    1e-9 to 1e-5 mol/mol, `vor850` +/-6.4e-5 1/s, `pres_sfc` 539-1036 hPa.

The hiopy run was repeated after the environment moved from `$HOME/icon_env`
to `<source root>/experiments`, and reproduced the earlier store exactly: same
198 arrays, same shapes, same value ranges.

Not exercised: dedicated I/O ranks, healpix output (hiopy is configured for the
model grid here), s3 storage, and any run longer than one chunk.
