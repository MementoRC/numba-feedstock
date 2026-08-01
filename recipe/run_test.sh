#!/bin/bash

set -euxo pipefail
IFS=$'\n\t'

export NUMBA_DEVELOPER_MODE=1
export NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1
export PYTHONFAULTHANDLER=1

# Windows runs the tests via run_test.bat (cmd); this script handles unix only.
SEGVCATCH=""
if [[ "$(uname)" == "Linux" ]]; then
  if command -v catchsegv >/dev/null 2>&1; then
    SEGVCATCH=catchsegv
  fi
  export CC="${QEMU_EXECVE} ${CC} -pthread"
fi

TEST_NPROCS="${CPU_COUNT}"
FAST_TESTS="${FAST_TESTS:-0}"

# Check test discovery works
${QEMU_EXECVE} ${PYTHON} -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$("${QEMU_EXECVE}" ${PYTHON} -c "$_NPY_CMD")" == "True" ]]; then
  export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
fi

# Vary which subset of tests --random selects across CI runs/architectures
# instead of always sampling the same fixed subset (numba's own default
# random_seed is a hardcoded 42 -- see recipe/patches/0002-...). Only
# override when running in real CI (flow_run_id set); local build-locally.py
# runs stay on numba's reproducible default for easier debugging.
if [[ -n "${flow_run_id:-}" && "${flow_run_id}" != "0" ]]; then
  NUMBA_TEST_RANDOM_SEED="$(echo -n "${flow_run_id}-${target_platform}" | cksum | cut -d' ' -f1)"
  export NUMBA_TEST_RANDOM_SEED
  echo "Randomizing numba test selection: NUMBA_TEST_RANDOM_SEED=${NUMBA_TEST_RANDOM_SEED} (from flow_run_id=${flow_run_id} target_platform=${target_platform})"
fi

if [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.15"  # ~ 1:49hr for ppc64le on x86_64, 55m on aarch64! \o/, true random + 5 builds should help more coverage
elif [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "0" ]]; then
  RANDOM_ARG="--random=0.15"
elif [[ "$target_platform" == "osx-64" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.5"
else
  RANDOM_ARG=""
fi

$SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -b $RANDOM_ARG --exclude-tags=long_running -m "$TEST_NPROCS"
