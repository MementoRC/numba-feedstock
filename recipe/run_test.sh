#!/bin/bash

set -euxo pipefail
IFS=$'\n\t'

# --- run the guest under qemu-execve, not vanilla qemu (reverts #201) --------
# qemu-execve-ppc64le 11.0.3 build 5 is arch-aware: it forwards execve() of a
# NATIVE build-platform binary straight to the host kernel, and only routes
# FOREIGN ppc64le ELFs back through emulation. That fixes what #201 hit with
# the older build, where every guest execve was intercepted indiscriminately
# and guest python therefore could not exec the build-platform cross-compiler.
#
# The guest must be LAUNCHED BY qemu-execve for interception to exist at all --
# it is a property of the emulating process, not of any environment variable.
# Launching with the vanilla qemu-ppc64le shipped in the same package leaves a
# guest whose own execve() syscalls go straight to the aarch64 host kernel,
# which cannot run a ppc64le ELF, so tests that spawn sys.executable themselves
# (test_pycc, test_parallel_backend) die with
# "OSError: [Errno 8] Exec format error".
#
# This also removes any dependence on kernel binfmt_misc, which conda-smithy's
# generated .github/workflows/conda-build.yml registers only on x86_64 hosts --
# never on the aarch64 hosts that actually run the ppc64le lanes
# (conda-forge.yml sets build_platform: linux_ppc64le -> linux_aarch64).
# See conda-forge/numba-feedstock#201 and #203.
export CROSSCOMPILING_EMULATOR="${QEMU_EXECVE}"
#
# Native-arch passthrough is OPT-IN and needs BOTH gates: QEMU_EXECVE non-empty
# (else execve dispatch never reaches qemu_execve() at all) and
# QEMU_EXECVE_NATIVE_PASSTHROUGH set. Without the second gate, a guest process
# exec'ing a NATIVE build-platform binary -- e.g. test_pycc / test_cffi invoking
# $BUILD_PREFIX/bin/powerpc64le-conda-linux-gnu-cc, which is an aarch64 driver
# that merely EMITS ppc64le -- falls through to qemu's standard ELF arch check
# and dies with "Invalid ELF image for this architecture". The qemu-execve
# package sets no default for either variable; the invoking environment must
# supply both. Harmless on native lanes, where QEMU_EXECVE is empty and
# qemu_execve() is never reached.
export QEMU_EXECVE_NATIVE_PASSTHROUGH=1

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

# --- qemu-execve native-passthrough quick-fail (conda-forge/numba-feedstock#203)
# Cheapest possible check that the native-arch passthrough gate set above is
# actually armed: make the GUEST python exec a NATIVE build-platform binary --
# the cross-compiler driver, an aarch64 executable that merely EMITS ppc64le.
# That nested execve is the exact operation that killed the whole
# test_pycc/test_cffi family in #203 ("Invalid ELF image for this
# architecture"). Probing it directly compiles nothing and costs a fraction of
# a second, so a broken gate fails HERE instead of ~40s later in the toolchain
# block below -- and it is cheap enough to run locally before pushing to CI.
#
# ${CC} has "-pthread" appended above, so strip arguments before exec'ing it.
# The path is passed as sys.argv[1] rather than interpolated into the -c source
# to avoid nested-quoting breakage.
_CC_BIN="${CC:-}"
_CC_BIN="${_CC_BIN%% *}"
if [[ -n "${QEMU_EXECVE:-}" && -n "${_CC_BIN}" ]]; then
  echo "VERIFY: qemu-execve native-arch passthrough (guest exec of ${_CC_BIN}) -- #203"
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "--version"])' \
    "${_CC_BIN}"
fi
# --- end native-passthrough quick-fail ---------------------------------------

# --- test_pycc failure triage probe (conda-forge/numba-feedstock#203) ---------
# The quick-fail above proves only that the guest can START the native cross-cc
# driver. It does not show whether that driver can then do its job. Two very
# different faults both surface as "the test_pycc family dies", and they have
# opposite fixes -- this block tells them apart in one CI run:
#
#   (A) RESOLUTION. The native driver starts but cannot find its own children
#       (cc1, as, collect2/ld) because the guest environment does not carry
#       $BUILD_PREFIX's exec dirs in PATH/COMPILER_PATH. The fix is environment,
#       right here in run_test.sh, and patch 0007's skip of TestDistutilsSupport
#       /test_compile_nrt would then be unnecessary rather than load-bearing.
#
#   (B) FOREIGN EXEC BELOW THE HANDOFF. The driver works and emits a valid
#       ppc64le binary, but nothing under it can RUN one. Native passthrough
#       hands the driver straight to the host kernel, which ends qemu-execve's
#       interception for that entire subtree, so any ppc64le ELF exec'd further
#       down gets no emulator. That is not fixable in this recipe: qemu-execve
#       would need an LD_PRELOAD shim to re-inject emulation into native
#       children.
#
# Every step is non-fatal (|| echo) so a single push reports ALL of them rather
# than stopping at the first. Read top-to-bottom: the first FAIL names the class.
if [[ -n "${QEMU_EXECVE:-}" && -n "${_CC_BIN:-}" ]]; then
  echo "PROBE: test_pycc triage -- resolution vs foreign-exec -- #203"
  _PROBE_DIR="$(mktemp -d)"
  printf 'int main(void){return 0;}\n' > "${_PROBE_DIR}/probe.c"

  # Step 1 -- the driver's own view of its search paths, read from INSIDE the
  # guest. This is the direct readout for fault class (A): if cc1 resolves to a
  # bare name rather than an absolute path, PATH/COMPILER_PATH is the problem.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "-print-search-dirs"])' \
    "${_CC_BIN}" || echo "PROBE FAIL step1: guest cannot query driver search dirs"
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "-print-prog-name=cc1"])' \
    "${_CC_BIN}" || echo "PROBE FAIL step1b: guest cannot resolve cc1"

  # Step 2 -- COMPILE. Forces the native driver to exec its own children (cc1,
  # as). A failure here naming cc1/as/ld is fault class (A), RESOLUTION.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "-c", sys.argv[2], "-o", sys.argv[3]])' \
    "${_CC_BIN}" "${_PROBE_DIR}/probe.c" "${_PROBE_DIR}/probe.o" \
    && echo "PROBE OK step2: guest-driven native cc produced an object" \
    || echo "PROBE FAIL step2: compile failed -- fault class (A), RESOLUTION"

  # Step 3 -- LINK an executable. Forces collect2/ld on top of step 2.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], sys.argv[2], "-o", sys.argv[3]])' \
    "${_CC_BIN}" "${_PROBE_DIR}/probe.c" "${_PROBE_DIR}/probe_exe" \
    && echo "PROBE OK step3: guest-driven native cc linked an executable" \
    || echo "PROBE FAIL step3: link failed -- fault class (A), RESOLUTION"

  # Confirm what was actually produced, so a green step2/step3 cannot be
  # mistaken for a driver that silently emitted host-arch output.
  file "${_PROBE_DIR}/probe_exe" 2>/dev/null || echo "PROBE note: 'file' unavailable"

  # Step 4 -- the decisive one. The GUEST execs the ppc64le binary it just
  # built. The guest was launched by qemu-execve, so its own execve is still
  # intercepted; this should succeed even under fault class (B).
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1]])' \
    "${_PROBE_DIR}/probe_exe" \
    && echo "PROBE OK step4: guest exec of a fresh ppc64le binary works" \
    || echo "PROBE FAIL step4: guest cannot exec its own ppc64le output"

  # Step 5 -- the LD_PRELOAD question, isolated. Route the same exec through a
  # NATIVE intermediary (/bin/sh, taken by passthrough to the host kernel).
  # step4 OK + step5 FAIL is the signature of fault class (B): interception
  # survives in the guest but is lost the moment a native child is handed off.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call(["/bin/sh", "-c", "exec \"$0\"", sys.argv[1]])' \
    "${_PROBE_DIR}/probe_exe" \
    && echo "PROBE OK step5: native child can exec a ppc64le binary (no shim needed)" \
    || echo "PROBE FAIL step5: fault class (B), FOREIGN EXEC BELOW HANDOFF -- qemu-execve needs an LD_PRELOAD shim"

  rm -rf "${_PROBE_DIR}"
  unset _PROBE_DIR
fi
unset _CC_BIN
# --- end test_pycc failure triage probe --------------------------------------

# --- unresolved-skip triage block (conda-forge/numba-feedstock#203) -----------
# The tests whose disposition is still open, run BY NAME and UNSAMPLED on every
# EMULATED lane. Supersedes the old ppc64le-gated skip audit and the separate
# fork gate: one block serves both lanes, because what differs per lane is the
# PATCH SET, not this block.
#
#   Lane where 0003/0007 ARE applied (ppc64le): these self-skip, and this block
#   is an AUDIT -- it proves "skipped", which a --random sampled log otherwise
#   cannot distinguish from "never drawn".
#   Lane where they are NOT applied: they may genuinely EXECUTE, which is the
#   open experiment -- are these QEMU gaps emulation-general, or specific to
#   QEMU's POWER target?
#
# CAVEAT LEARNED THE HARD WAY: "not applied" does NOT guarantee "executes".
# numba upstream carries @skip_if_linux_aarch64 on test_compile_nrt and
# TestDistutilsSupport, so on aarch64 those self-skip regardless of our patches
# and this lane CANNOT answer the 0007 question at all. Read the verdicts below
# literally -- SKIPPED is inconclusive, not evidence.
_triage_verdict() {
  # $1 label, $2 note-if-passed, rest = command to run.
  # A unittest run exits 0 in THREE distinct ways and only one is a pass:
  #   "Ran 0 tests"    -> `-k` matched nothing; the check was vacuous
  #   "OK (skipped=N)" -> ran, but every selected test self-skipped
  #   "OK"             -> genuinely executed and passed
  # Judging by exit status alone conflates all three. An earlier revision of
  # this block did exactly that and reported four skipped tests as "passed".
  local _label="$1"; shift
  local _note="$1"; shift
  local _out
  local _rc
  set +e
  _out="$("$@" 2>&1)"
  _rc=$?
  set -e
  printf '%s\n' "${_out}"
  if grep -qE '^Ran 0 tests' <<<"${_out}"; then
    _TRIAGE_LAST="NOTHING_SELECTED"
    echo "TRIAGE NOTHING_SELECTED: ${_label} -- pattern matched no test, INCONCLUSIVE (upstream rename?)"
  elif grep -qE '^OK \(skipped=' <<<"${_out}"; then
    _TRIAGE_LAST="SKIPPED"
    echo "TRIAGE SKIPPED: ${_label} -- INCONCLUSIVE, did not execute. Reason(s):"
    grep -oE "skipped '[^']*'" <<<"${_out}" | sort -u | sed 's/^/  /'
  elif [[ ${_rc} -eq 0 ]]; then
    _TRIAGE_LAST="PASSED"
    echo "TRIAGE PASSED: ${_label} -- ${_note}"
  else
    _TRIAGE_LAST="FAILED"
    echo "TRIAGE FAILED: ${_label} -- the gap DOES reproduce on this target"
  fi
}

if [[ -n "${QEMU_EXECVE:-}" ]]; then
  echo "TRIAGE: unresolved skip candidates (0003, 0007) + build-7 fork gate -- #203"
  _TRIAGE_LAST=""

  _triage_verdict "test_unique (0003)" \
    "gap does NOT reproduce here; 0003 unjustified on this target" \
    ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique \
    numba.tests.test_array_methods

  _triage_verdict "test_compile_nrt (0007)" \
    "gap does NOT reproduce here; 0007 unjustified on this target" \
    ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_compile_nrt \
    numba.tests.test_pycc

  _triage_verdict "TestDistutilsSupport (0007)" \
    "gap does NOT reproduce here; 0007 class skip unjustified on this target" \
    ${QEMU_EXECVE} ${PYTHON} -m unittest -v \
    numba.tests.test_pycc.TestDistutilsSupport

  # FATAL -- the build-7 fork fix gate. Patch 0004 was retired on the strength
  # of qemu-execve build 7, so anything other than a GENUINE pass must stop the
  # lane: a skip or a zero-match here would leave 0004's removal unverified,
  # which is indistinguishable from a silent regression.
  _triage_verdict "fork gate (qemu-execve >=7)" \
    "build-7 fork fix confirmed; 0004 stays retired" \
    $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m unittest -v \
    -k test_workqueue_handles_fork_from_non_main_thread \
    numba.tests.test_parallel_backend
  if [[ "${_TRIAGE_LAST}" != "PASSED" ]]; then
    echo "TRIAGE FATAL: fork gate verdict was ${_TRIAGE_LAST}, not PASSED -- restore patch 0004"
    exit 1
  fi
fi

# LOCAL DIAGNOSTIC MODE. Stop here, before the expensive forefronted blocks and
# the full --random suite. CI never sets NUMBA_CF_TRIAGE, and recipe.yaml
# defaults it to "0", so CI behaviour is completely unchanged. Placing this exit
# early means nothing below needs its own opt-out.
if [[ "${NUMBA_CF_TRIAGE:-0}" == "1" ]]; then
  echo "TRIAGE: NUMBA_CF_TRIAGE=1 -- stopping before the full test suite"
  exit 0
fi
# --- end unresolved-skip triage block ----------------------------------------

# --- forefronted known-red tests, ALL platforms (conda-forge/numba-feedstock#203)
# Mirror of the win_64 block in run_test.bat lines 31-36, extended to every unix
# lane. Run serially and UNSAMPLED so they execute identically on every lane and
# every python version.
#
# Why this is needed: the main suite below is --random sampled, so a test absent
# from a log may simply never have been drawn. That makes it impossible to tell
# "passed", "skipped" and "not selected" apart, and impossible to characterise a
# flaky failure. Forefronting gives a deterministic per-lane signal.
#
# test_linalg_lstsq is nondeterministic by nature: numba checks infs/NaN BEFORE
# emptiness in lstsq, so the content of the uninitialized LAPACK workspace decides
# which LinAlgError surfaces for a zero-size input. Observed FAIL/PASS/FAIL on
# win_64, and recorded known-red on win_64 py3.11 and py3.14t. Running it on unix
# too establishes whether it is Windows-specific or general.
#
# ${QEMU_EXECVE} is empty on native lanes and expands away; on cross lanes it is
# the emulator. It stays UNQUOTED for exactly that reason.
echo "VERIFY: forefronted known-red tests (lstsq, charseq, recursion) -- #203"
$SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
  numba.tests.test_linalg.TestLinalgLstsq.test_linalg_lstsq \
  numba.tests.test_record_dtype.TestRecordDtypeWithCharSeq.test_npm_argument_charseq \
  numba.tests.test_recursion
# --- end forefronted known-red tests -----------------------------------------

# --- ppc64le fix guards (conda-forge/numba-feedstock#192) ---------------------
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  # Deterministic fast guard on the two ppc64le test FIXES (patches 0005 and
  # 0006): run them up front so a regression in the patched expected value
  # fails in seconds -- and so they are always checked even on the random test
  # slices that would otherwise exclude them. The QEMU-artifact SKIPS (0003,
  # 0004, 0007) are audited separately below.
  # See conda-forge/numba-feedstock#192.
  echo "VERIFY: ppc64le test fixes (test_inlining_global_dispatcher, test_array_const_alignment) -- #192"
  $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_function_type.TestInliningFunctionType.test_inlining_global_dispatcher \
    numba.tests.test_array_constants.TestConstantArray.test_array_const_alignment
fi
# ------------------------------------------------------------------------------



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
# `${QEMU_EXECVE} ${PYTHON}` so the probe runs under emulation on the
# ppc64le-on-aarch64 cross build. QEMU_EXECVE stays UNQUOTED -- it is empty on
# native platforms, and a quoted empty expansion is an unrunnable argv[0].
# Left unguarded, as on main, so it also runs natively where it would catch a
# signext change that breaks x86_64.
${QEMU_EXECVE} ${PYTHON} -c "
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
$SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests numba.tests.test_mathlib.TestMathLib.test_ldexp -v
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
  $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
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
${QEMU_EXECVE} ${PYTHON} -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$(${QEMU_EXECVE} ${PYTHON} -c "$_NPY_CMD")" == "True" ]]; then
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

$SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -b $RANDOM_ARG --exclude-tags=long_running -m "$TEST_NPROCS"
