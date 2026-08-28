#!/bin/bash

set -euxo pipefail
IFS=$'\n\t'

# --- qemu-execve interception, arch-aware since build 5 -----------------------
# qemu-execve-ppc64le 11.0.3 build 5 routes execve() by ELF arch: foreign
# ppc64le binaries go through qemu, native build-platform binaries exec
# through untouched. That fixes the reason #201 disabled interception (the
# older build intercepted every guest execve indiscriminately, so guest
# python could not exec the build-platform cross-compiler), and it removes
# the dependency on kernel binfmt_misc -- which conda-smithy's generated
# .github/workflows/conda-build.yml only registers on x86_64 hosts, never on
# the aarch64 hosts that actually run the ppc64le lanes (conda-forge.yml sets
# build_platform: linux_ppc64le -> linux_aarch64). Without interception,
# tests that spawn sys.executable themselves (test_pycc,
# test_parallel_backend) die with "OSError: [Errno 8] Exec format error".
#
# QEMU_EXECVE stays SET so nested guest execs are intercepted. QEMU_RUN is
# the vanilla qemu-<arch> shipped by the same package, still needed as an
# explicit prefix for the top-level launch of ppc64le ${PYTHON} from host
# bash -- that exec is not made by a process already running under qemu.
# See conda-forge/numba-feedstock#201 and #203.
QEMU_RUN="${QEMU_EXECVE/qemu-execve-/qemu-}"
export CROSSCOMPILING_EMULATOR="${QEMU_RUN}"

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

# --- ppc64le fix guards (conda-forge/numba-feedstock#192) ---------------------
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  # Deterministic fast guard on the two ppc64le test FIXES (patches 0005 and
  # 0006): run them up front so a regression in the patched expected value
  # fails in seconds -- and so they are always checked even on the random test
  # slices that would otherwise exclude them. The QEMU-artifact SKIPS (0003,
  # 0004, 0007) are audited separately below.
  # See conda-forge/numba-feedstock#192.
  echo "VERIFY: ppc64le test fixes (test_inlining_global_dispatcher, test_array_const_alignment) -- #192"
  $SEGVCATCH ${QEMU_RUN} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_function_type.TestInliningFunctionType.test_inlining_global_dispatcher \
    numba.tests.test_array_constants.TestConstantArray.test_array_const_alignment
fi
# ------------------------------------------------------------------------------

# --- ppc64le QEMU-artifact skip audit (conda-forge/numba-feedstock#192) -------
# Patches 0003, 0004, and 0007 SKIP three tests that are QEMU/TCG emulation
# artifacts, not numba defects. Because nothing runs them by name, a test that
# is skipped and a test the sampled --random slice simply never drew look
# IDENTICAL in the log -- both are just absent. That ambiguity cost real
# triage time in conda-forge/numba-feedstock#201.
#
# This block resolves the ambiguity by naming all three explicitly, so every
# run states their status in the log rather than leaving it implicit. It is
# an AUDIT, not a value regression test: patch application already fails the
# build outright if a target method vanishes upstream. What this adds is
# visibility, detection of upstream method renames, and a standing trigger to
# revisit these skips if the underlying QEMU gap is ever fixed, instead of
# silently inheriting them forever.
#
# Stock `unittest -k` is used here rather than `numba.runtests <dotted.name>`
# because the skip patches match on METHOD NAME only -- the enclosing class
# names are not pinned anywhere else in this recipe -- so `-k` avoids
# hardcoding a class name upstream could refactor away. These tests are
# expected to SKIP, so they never execute a body and do not need
# numba.runtests' harness. Note 0004's real target is
# test_workqueue_handles_fork_from_non_main_thread; test_workqueue_fork is
# only the patch filename.
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  echo "AUDIT: ppc64le QEMU-artifact skips (patches 0003, 0004, 0007) -- #192"
  ${QEMU_RUN} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods
  ${QEMU_RUN} ${PYTHON} -m unittest -v -k test_workqueue_handles_fork_from_non_main_thread numba.tests.test_parallel_backend
  ${QEMU_RUN} ${PYTHON} -m unittest -v -k test_compile_nrt numba.tests.test_pycc
fi
# --- end ppc64le QEMU-artifact skip audit --------------------------------------

TEST_NPROCS="${CPU_COUNT}"
FAST_TESTS="${FAST_TESTS:-0}"

# --- ppc64le ldexp/frexp quick-fail probe (numba#8489) -----------------------
# The suite at the end of this script runs with --random on cross-compiled
# targets, so test_mathlib.TestMathLib.test_ldexp may never be drawn. Verify the
# ELFv2 signext fix directly, and fail fast and loudly here if it regresses.
#
# math.ldexp with a NEGATIVE exponent crosses the JIT -> numba_ldexp C helper
# boundary. Without the `signext` attribute on the i32 exponent argument, LLVM
# zero-extends it (clrldi), so -2 arrives as 4294967294 and the result is inf
# instead of 0.625. frexp is included as a control: its helper takes int* (a
# 64-bit pointer), which has no sub-word extension issue.
#
# np.ldexp is a SEPARATE declaration site from math.ldexp: the scalar path is
# declared in numba/cpython/mathimpl.py, while the ufunc path is declared in
# numba/np/math/mathimpl.py via numba/np/npyfuncs.py. A signext fix to one
# does not cover the other, so both are probed here.
#
# Adopted from main and adapted for rc: plain `python` becomes
# `${QEMU_RUN} ${PYTHON}` so the probe runs under emulation on the
# ppc64le-on-aarch64 cross build. QEMU_RUN stays UNQUOTED -- it is empty on
# native platforms, and a quoted empty expansion is an unrunnable argv[0].
# Left unguarded, as on main, so it also runs natively where it would catch a
# signext change that breaks x86_64.
${QEMU_RUN} ${PYTHON} -c "
import math
import numpy as np
from numba import njit

@njit
def jit_ldexp(x, e):
    return math.ldexp(x, e)

@njit
def jit_np_ldexp(x, e):
    return np.ldexp(x, e)

@njit
def jit_frexp(x):
    return math.frexp(x)

failures = []
for x, e, want in ((2.5, -2, 0.625), (1.0, -1, 0.5), (2.5, 0, 2.5), (3.0, 4, 48.0)):
    got = jit_ldexp(x, e)
    print('ldexp(%r, %r) = %r  want %r' % (x, e, got, want))
    if got != want:
        failures.append('ldexp(%r, %r) -> %r != %r' % (x, e, got, want))

for x, e, want in ((2.5, -2, 0.625), (1.0, -1, 0.5), (2.5, 0, 2.5), (3.0, 4, 48.0)):
    got = jit_np_ldexp(x, e)
    print('np.ldexp(%r, %r) = %r  want %r' % (x, e, got, want))
    if got != want:
        failures.append('np.ldexp(%r, %r) -> %r != %r' % (x, e, got, want))

_INT32_MIN = -(2 ** 31)
for label, fn in (('ldexp', jit_ldexp), ('np.ldexp', jit_np_ldexp)):
    got = fn(2.5, _INT32_MIN)
    print('%s(2.5, INT32_MIN) = %r  want 0.0' % (label, got))
    if got != 0.0:
        failures.append('%s(2.5, INT32_MIN) -> %r != 0.0' % (label, got))

got = jit_frexp(0.625)
print('frexp(0.625) = %r  want (0.625, 0)' % (got,))
if got != (0.625, 0):
    failures.append('frexp(0.625) -> %r != (0.625, 0)' % (got,))

if failures:
    raise SystemExit('ppc64le ldexp/frexp ABI regression:' + ''.join(['\n  ' + f for f in failures]))
print('ldexp/np.ldexp/frexp signext probe OK')
"
# Run the upstream test explicitly too, since the sampled suite may not select it.
$SEGVCATCH ${QEMU_RUN} ${PYTHON} -m numba.runtests numba.tests.test_mathlib.TestMathLib.test_ldexp -v
# --- end ppc64le probe -------------------------------------------------------

# --- cross-build toolchain quick-fail (conda-forge/numba-feedstock#201) -------
# Every test listed below invokes the C or C++ toolchain at test time. These are
# precisely the tests that failed across the four ppc64le lanes of PR #201 when
# the test environment carried no build-platform compiler.
#
# They are run deterministically and UP FRONT for one reason: the suite at the
# end of this script is sampled (--random), so it draws a different member of
# this family on each run. A green sampled suite is therefore NOT evidence that
# the test-time toolchain is present. Running them here fails in minutes rather
# than after the full ~50 minute suite.
#
# test_lifetime_of_task_scheduler_handle is NOT a toolchain test, but it has
# now been characterised. On the green ppc64le py3.13 lane of run
# 33005537482 it reported: skipped "Compilation of DSO failed. Check output
# for details". The root cause is a dependency asymmetry, not an emulation
# failure: the test env resolves tbb (runtime) but tbb-devel (headers) is
# only in the BUILD env, so no TBB-linked DSO can be compiled at test time.
# It is not emulation-related: the five other tests in this block also
# invoke powerpc64le-conda-linux-gnu-cc under the same emulator and all
# passed. Confidence is MEDIUM, not high: numba's harness swallows the
# compiler stderr, so the underlying error text was never captured in the
# log. It is kept in this list so the skip stays visible; adding tbb-devel
# to the test requirements would make it actually execute.
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  echo "VERIFY: test-time C/C++ toolchain availability -- see conda-forge/numba-feedstock#201"
  $SEGVCATCH ${QEMU_RUN} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_pycc.TestCC.test_compile_for_cpu \
    numba.tests.test_pycc.TestCC.test_dynamic_exc \
    numba.tests.test_pycc.TestCC.test_hashing \
    numba.tests.test_pycc.TestCC.test_reproducible_build \
    numba.tests.test_pycc.TestDistutilsSupport.test_setup_py_distutils \
    numba.tests.test_pycc.TestDistutilsSupport.test_setup_py_setuptools_nested \
    numba.tests.test_cffi.TestCFFI.test_from_buffer_numpy_multi_array \
    numba.tests.test_parallel_backend.TestTBBSpecificIssues.test_lifetime_of_task_scheduler_handle
fi
# --- end toolchain quick-fail ------------------------------------------------

# Check test discovery works
${QEMU_RUN} ${PYTHON} -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$("${QEMU_RUN}" ${PYTHON} -c "$_NPY_CMD")" == "True" ]]; then
  export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
fi

# Vary which subset of tests --random selects across CI runs/architectures
if [[ -n "${flow_run_id:-}" && "${flow_run_id}" != "0" ]]; then
  NUMBA_TEST_RANDOM_SEED="$(echo -n "${flow_run_id}-${target_platform}-${python_version}" | cksum | cut -d' ' -f1)"
  export NUMBA_TEST_RANDOM_SEED
  echo "Randomizing numba test selection: NUMBA_TEST_RANDOM_SEED=${NUMBA_TEST_RANDOM_SEED} (from flow_run_id=${flow_run_id} target_platform=${target_platform} python_version=${python_version})"
fi

if [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.15"  # ~ 1:49hr for ppc64le on x86_64, 55m on aarch64! \o/, true random + 5 builds should help more coverage
elif [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "0" ]]; then
  RANDOM_ARG="--random=0.25"
elif [[ "$target_platform" == "osx-64" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.5"
else
  RANDOM_ARG=""
fi

$SEGVCATCH ${QEMU_RUN} ${PYTHON} -m numba.runtests -b $RANDOM_ARG --exclude-tags=long_running -m "$TEST_NPROCS"
