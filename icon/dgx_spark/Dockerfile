# syntax=docker/dockerfile:1
#
# ICON build+run environment for Dolpung-style *hybrid* jobs on a single
# NVIDIA GB10 (Grace Blackwell / DGX Spark).
#
# A hybrid job in ICON's sense means one MPMD job in which the atmosphere runs
# on the GPU and the ocean runs on the CPU, coupled through YAC, optionally with
# hiopy output workers alongside. On Dolpung that is expressed by an mkexp
# experiment whose [[[hybrid]]] section names two *separate executables*, one
# from each of two out-of-source builds of the same source tree:
#
#     atm  ->  $ICON_BUILD_DIR_GPU/bin/icon
#     oce  ->  $ICON_BUILD_DIR_CPU/bin/icon
#
# So this image is set up to produce those two builds and to launch them
# together. build-icon.sh does the builds -- following the same sequence as the
# Dolpung setup script, down to installing YAC from the CPU build so that hiopy
# can link against it -- and run-hybrid.sh launches them. Both sit next to this
# file, together with the two configure wrappers they use,
# gb10.gpu.nvhpc and gb10.cpu.nvhpc, which are this container's counterpart of
# config/dkrz/dolpung.{gpu,cpu}.nvhpc-25.7.
#
# ---------------------------------------------------------------------------
# How this differs from a Dolpung node, which matters for the run layout
# ---------------------------------------------------------------------------
#
#   Dolpung node : 4x GH200, 4 NUMA domains, 288 cores, SLURM, srun --multi-prog
#   GB10 Spark   : 1x Blackwell, 1 NUMA domain, 20 cores, no scheduler
#
# So: no srun, no hostfile, no per-rank NUMA/NIC map. run-hybrid.sh uses
# OpenMPI's own MPMD form (`mpirun -np N a.out : -np M b.out`) and pins by core
# range instead. The rank counts that make sense here are single digits, not the
# hundreds a Dolpung experiment config assumes -- adjust the experiment
# accordingly or it will simply not fit.
#
# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------
#
# nvcr.io/nvidia/nvhpc:*-devel-* is the right base: it carries nvfortran (ICON's
# OpenACC support is nvfortran-specific), nvc/nvc++, CUDA, and a bundled
# CUDA-aware OpenMPI, all built for aarch64. A plain nvidia/cuda image has no
# Fortran compiler and is not usable here.
#
# CUDA 13 rather than 12.x: GB10 is a recent Blackwell part, and the CUDA 12.9
# toolkit does not target it. 25.9 is the SDK release paired with CUDA 13.0.
#
# Verified: nvcr.io/nvidia/nvhpc publishes linux/arm64 manifests for this tag.

ARG NVHPC_VERSION=25.9
ARG CUDA_VERSION=13.0
ARG UBUNTU_VERSION=24.04
FROM nvcr.io/nvidia/nvhpc:${NVHPC_VERSION}-devel-cuda${CUDA_VERSION}-ubuntu${UBUNTU_VERSION}

ARG NVHPC_VERSION
ARG CUDA_VERSION
ARG NETCDF_FORTRAN_VERSION=4.6.1
ARG NETCDF_FORTRAN_SHA256=b50b0c72b8b16b140201a020936aa8aeda5c79cf265c55160986cd637807a37a

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# ICON's documented Ubuntu dependency set, minus the compilers and MPI (which
# come from the HPC SDK), plus what a *coupled* configuration needs on top of a
# plain atmosphere-only one: libfyaml and libxml2 for YAC's configuration
# parsing, and the C++ toolchain YAC itself is partly written in.
#
# eccodes is deliberately not installed: GRIB2 output is not enabled in this
# image, so nothing would link against it.
#
# `sudo` is installed because the user created at the end of this file is put in
# the sudo group and given a sudoers rule -- without the package that rule is
# dead configuration.
#
# NetCDF-Fortran is the one dependency that cannot come from apt: Fortran .mod
# files are compiler-specific, so a gfortran-built libnetcdff is unreadable by
# nvfortran. It is built below. Everything else -- including the gfortran-built
# BLAS/LAPACK -- links by symbol name and mixes fine.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bzip2 ca-certificates cmake curl file git \
        libblas-dev liblapack-dev \
        libfyaml-dev libhdf5-dev \
        libnetcdf-dev libxml2-dev \
        m4 make numactl openssh-client perl pkg-config \
        python3 python3-dev python3-venv \
        rsync sudo tini unzip \
    && rm -rf /var/lib/apt/lists/*

# The SDK's install directory is architecture-specific and a RUN cannot write
# back into ENV, so resolve it once into a stable symlink. The `test -d` turns a
# wrong architecture or version into a build-time failure rather than a
# confusing "mpifort: not found" hours later.
RUN set -eu; \
    arch="$(uname -m)"; \
    case "${arch}" in \
        aarch64) nvarch=Linux_aarch64 ;; \
        x86_64)  nvarch=Linux_x86_64 ;; \
        *) echo "unsupported architecture '${arch}'" >&2; exit 1 ;; \
    esac; \
    test -d "/opt/nvidia/hpc_sdk/${nvarch}/${NVHPC_VERSION}"; \
    ln -s "${nvarch}/${NVHPC_VERSION}" /opt/nvidia/hpc_sdk/current

# CUDA_HOME points at the *versioned* toolkit directory, not at the cuda/
# aggregate. cuda/ only symlinks bin, include, lib64 and nvvm out of it; it has
# no targets/ subdirectory, and CMake's FindCUDAToolkit derives the include path
# of the imported CUDA::cudart target as <root>/targets/<triple>/include. With
# CUDAToolkit_ROOT=<...>/cuda the CMake-built externals (memman, fortran-support)
# fail with "Imported target CUDA::cudart includes non-existent path". This
# mirrors config/dkrz/dolpung.gpu.nvhpc-25.7, which sets CUDA_ROOT to cuda/12.9.
ENV NVHPC_ROOT=/opt/nvidia/hpc_sdk/current \
    MPI_ROOT=/opt/nvidia/hpc_sdk/current/comm_libs/mpi \
    CUDA_HOME=/opt/nvidia/hpc_sdk/current/cuda/${CUDA_VERSION} \
    NETCDFF_ROOT=/opt/netcdf-fortran
ENV PATH=${MPI_ROOT}/bin:${NETCDFF_ROOT}/bin:${PATH} \
    LD_LIBRARY_PATH=${NETCDFF_ROOT}/lib:${LD_LIBRARY_PATH}

# NetCDF-Fortran compiled with nvfortran, so its .mod files are readable by
# ICON's own build.
RUN set -eu; \
    mkdir -p /tmp/nf && cd /tmp/nf; \
    curl -fsSLO "https://downloads.unidata.ucar.edu/netcdf-fortran/${NETCDF_FORTRAN_VERSION}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}.tar.gz"; \
    echo "${NETCDF_FORTRAN_SHA256}  netcdf-fortran-${NETCDF_FORTRAN_VERSION}.tar.gz" | sha256sum --check --strict; \
    tar -xzf "netcdf-fortran-${NETCDF_FORTRAN_VERSION}.tar.gz"; \
    cd "netcdf-fortran-${NETCDF_FORTRAN_VERSION}"; \
    ./configure --prefix="${NETCDFF_ROOT}" --enable-shared --disable-static \
        CC=nvc FC=nvfortran F77=nvfortran \
        CFLAGS='-O2 -fPIC' FCFLAGS='-O2 -fPIC' FFLAGS='-O2 -fPIC' \
        CPPFLAGS="$(nc-config --cflags)" \
        LDFLAGS="-L$(nc-config --libdir)" LIBS='-lnetcdf'; \
    make -j"$(nproc)" && make install; \
    cd / && rm -rf /tmp/nf

# A Python environment for post-processing and for hiopy. Kept outside the ICON
# tree so a bind-mounted source directory stays untouched.
#
# cython/wheel/setuptools are here because the CPU build is configured with
# --enable-bundled-python=yac,mtime: building YAC's Python binding is what forces
# YAC and its dependency chain to be built -fPIC, which is what hiopy then needs.
# hiopy does not use the binding itself; building it is the check.
#
# hiopy itself is NOT installed here: it builds against the coyote library of the
# very ICON build you are about to make, so it has to be installed after that
# build, not before. build-icon.sh does it as its last step, into a second venv
# it creates under the environment directory -- /opt/venv belongs to root and a
# build run as the icon user cannot add to it.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "${VIRTUAL_ENV}" \
    && "${VIRTUAL_ENV}/bin/pip" install --quiet --no-cache-dir --upgrade pip wheel setuptools \
    && "${VIRTUAL_ENV}/bin/pip" install --quiet --no-cache-dir \
        "cython" "jinja2>=3.1" "isodate" "numpy" "xarray" "netCDF4" "zarr>=3" "dask"
ENV PATH=${VIRTUAL_ENV}/bin:${PATH}

# Running MPI as root is refused by default, and a container is usually root.
# OpenMPI 4 reads OMPI_*; OpenMPI 5 delegates launch to PRRTE, which reads
# PRTE_*. Setting both means whichever the SDK bundles is covered.
ENV OMPI_ALLOW_RUN_AS_ROOT=1 \
    OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 \
    PRTE_ALLOW_RUN_AS_ROOT=1 \
    PRTE_ALLOW_RUN_AS_ROOT_CONFIRM=1 \
    OMPI_MCA_rmaps_base_oversubscribe=1 \
    PRTE_MCA_rmaps_default_mapping_policy=:oversubscribe

# The SDK ships HPC-X's Open MPI relocated from the path it was built at, so
# without OPAL_PREFIX every diagnostic it tries to print turns into
# "couldn't open the help file: /proj/nv/libraries/.../help-opal-runtime.txt",
# which hides whatever it was actually trying to tell you.
#
# ORTE's rtc/hwloc component memory-binds each rank at launch. That fails inside
# a container that cannot mbind, and the reaction is a five-line warning on every
# single launch -- while hwloc_base_mem_bind_failure_action=silent, the setting
# that looks like it should suppress it, does not. Turning the component off
# removes the memory binding, which is meaningless on a one-NUMA-domain machine,
# and leaves *process* binding to cores untouched, which is not.
#
# HCOLL is HPC-X's collective-offload library and wants an InfiniBand HCA. There
# is none here, so every communicator creation prints a four-line "You must
# specify a valid HCA device" block followed by "Hcol library init failed" --
# per rank, per communicator. ICON creates a lot of communicators.
ENV OPAL_PREFIX=/opt/nvidia/hpc_sdk/current/comm_libs/mpi \
    OMPI_MCA_rtc=^hwloc \
    OMPI_MCA_coll_hcoll_enable=0

# Runtime tuning carried over from dolpung_gpu.config / dolpung_hybrid.config.
# The UCX transport list is deliberately *not* copied: Dolpung's value names
# InfiniBand transports (rc_x, ud_x) that do not exist on a single Spark, and
# forcing them makes UCX fail to initialise rather than fall back. Shared memory
# and CUDA IPC are what a one-node job actually uses.
ENV OMP_DYNAMIC=false \
    OMP_SCHEDULE=guided \
    OMP_STACKSIZE=500M \
    UCX_TLS=self,sm,cuda_copy,cuda_ipc \
    UCX_HANDLE_ERRORS=bt \
    NVCOMPILER_ACC_DEFER_UPLOADS=1 \
    NVCOMPILER_ACC_USE_GRAPH=1 \
    NVCOMPILER_TERM=trace \
    MALLOC_CONF=thp:never \
    HDF5_USE_FILE_LOCKING=FALSE

COPY build-icon.sh run-hybrid.sh make-experiment.sh /usr/local/bin/
# The two configure wrappers are the container's equivalent of
# config/dkrz/dolpung.{gpu,cpu}.nvhpc-25.7. They live in the image as well as in
# the source tree so that build-icon.sh works against a source checkout that
# predates them; ICON_CONFIG_DIR overrides the location.
COPY gb10.gpu.nvhpc gb10.cpu.nvhpc /usr/local/share/icon-gb10/
RUN chmod 0755 /usr/local/bin/build-icon.sh /usr/local/bin/run-hybrid.sh \
                /usr/local/bin/make-experiment.sh \
                /usr/local/share/icon-gb10/gb10.gpu.nvhpc \
                /usr/local/share/icon-gb10/gb10.cpu.nvhpc
ENV ICON_CONFIG_DIR=/usr/local/share/icon-gb10

# The ICON source is expected to be bind-mounted rather than baked in, so the
# image stays reusable while you edit the model:
#     docker run --gpus all -v /path/to/icon:/home/icon/icon ...
#
# ICON_UID/ICON_GID must match the owner of that bind-mounted directory. A
# container user whose uid differs from the host owner's cannot write into the
# mount, and the build needs to write there: `git submodule update --init` has
# to populate externals/ before anything can be configured. Pass the host values
# at build time:
#     docker build --build-arg ICON_UID="$(id -u)" --build-arg ICON_GID="$(id -g)" ...
ARG ICON_UID=1002
ARG ICON_GID=1002
RUN set -eu; \
    if ! getent group "${ICON_GID}" >/dev/null; then \
        groupadd --gid "${ICON_GID}" icon; \
    fi; \
    useradd --create-home --home-dir /home/icon --shell /bin/bash \
            --uid "${ICON_UID}" --gid "${ICON_GID}" --groups sudo icon; \
    echo '%icon ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER icon
WORKDIR /home/icon

# ICON's submodules are declared with URLs relative to the origin remote, which
# on the upstream repositories is ssh (git@gitlab.dkrz.de:...). A container has
# no ssh key, but every submodule this build needs is readable anonymously over
# https, so rewrite the scheme once, globally, for the icon user. Without this
# `git submodule update --init` fails with "Permission denied (publickey)".
RUN git config --global url."https://gitlab.dkrz.de/".insteadOf "git@gitlab.dkrz.de:" \
 && git config --global --add safe.directory '*'

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/icon/.local/bin:${PATH}"

RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/icon/.opencode/bin:${PATH}"

# tini so that a Ctrl-C reaches mpirun and its children rather than leaving
# orphaned ranks holding the GPU.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash"]
