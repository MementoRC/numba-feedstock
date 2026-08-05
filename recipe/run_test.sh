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
  export CC="${CC} -pthread"
fi

TEST_NPROCS="${CPU_COUNT}"
FAST_TESTS="${FAST_TESTS:-0}"

# Validate Numba dependencies
python -m pip check
# Check Numba executables are present
numba -h
# System info tool
numba -s
# Check test discovery works
python -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$(python -c "$_NPY_CMD")" == "True" ]]; then
  export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
fi

if [[ "$build_platform" != "$target_platform" ]]; then
  RANDOM_ARG="--random=0.08"
elif [[ "$target_platform" == "osx-64" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.5"
else
  RANDOM_ARG=""
fi

$SEGVCATCH python -m numba.runtests -b $RANDOM_ARG --exclude-tags=long_running -m "$TEST_NPROCS"
