#!/bin/bash

set -euxo pipefail
IFS=$'\n\t'

export NUMBA_DEVELOPER_MODE=1
export NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1
export PYTHONFAULTHANDLER=1

unamestr=`uname`
case "$unamestr" in
  Linux*)
    if command -v catchsegv >/dev/null 2>&1; then
      SEGVCATCH=catchsegv
    else
      SEGVCATCH=""
    fi
    export CC="${CC} -pthread"
    ;;
  Darwin*)
    SEGVCATCH=""
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows*)
    SEGVCATCH=""
    export NUMBA_CPU_NAME=generic
    export _NUMBA_REDUCED_TESTING=1
    export PYTHONUTF8=1
    ;;
  *)
    SEGVCATCH=""
    ;;
esac

TEST_NPROCS=${CPU_COUNT}
FAST_TESTS="${FAST_TESTS:-"0"}"

# Validate Numba dependencies
python -m pip check

# Check Numba executables are there
numba -h

# run system info tool
numba -s

# Check test discovery works
python -m numba.tests.test_runtests

# Disable NumPy dispatching to AVX512_SKX feature extensions if the chip is
# reported to support the feature and NumPy >= 1.22 as this results in the use
# of low accuracy SVML libm replacements in ufunc loops.
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
NUMPY_DETECTS_AVX512_SKX_NP_GT_122=$(python -c "$_NPY_CMD")
echo "NumPy >= 1.22 with AVX512_SKX detected: $NUMPY_DETECTS_AVX512_SKX_NP_GT_122"

if [[ "$NUMPY_DETECTS_AVX512_SKX_NP_GT_122" == "True" ]]; then
  export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
fi

if [[ "$build_platform" != "$target_platform" ]]; then
  echo "Randomizing numba test suite because $build_platform != $host_platform"
  echo "Running: $SEGVCATCH python -m numba.runtests -b --random='0.07' -m $TEST_NPROCS"
  $SEGVCATCH python -m numba.runtests -b --random='0.08' --exclude-tags='long_running' -m $TEST_NPROCS
elif ([[ "$target_platform" == "win-"* ]] || [[ "$target_platform" == "osx-64" ]]) && [[ "${FAST_TESTS}" == "1" ]]; then
  echo "Running half the tests except long_running on '$target_platform'"
  echo "Running: $SEGVCATCH python -m numba.runtests -b --random='0.5' -m $TEST_NPROCS"
  $SEGVCATCH python -m numba.runtests -b --random='0.5' --exclude-tags='long_running' -m $TEST_NPROCS
else
  echo "Running all the tests except long_running on '$target_platform'"
  echo "Running: $SEGVCATCH python -m numba.runtests -b -m $TEST_NPROCS"
  $SEGVCATCH python -m numba.runtests -b --exclude-tags='long_running' -m $TEST_NPROCS
fi
