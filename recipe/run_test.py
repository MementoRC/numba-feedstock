#!/usr/bin/env python
"""conda-forge numba test runner.

Ported from run_test.sh to run under rattler-build `interpreter: python`.
Rationale: with `interpreter: bash` on Windows, rattler runs the test via the
MSYS bash.exe that lives inside the test prefix; that resident interpreter's
own image locks the test dir and rattler-build cleanup fails with
"Access is denied (os error 5)". A native python.exe interpreter exits cleanly
and releases its handle, and no bash.exe is spawned at all.

The actual numba test run stays a SUBPROCESS so PYTHONUTF8 / NUMBA_CPU_NAME /
NPY_DISABLE_CPU_FEATURES take effect in the child that runs the tests.
"""
import os
import shutil
import subprocess
import sys
import tempfile

PY = sys.executable
env = dict(os.environ)

env["NUMBA_DEVELOPER_MODE"] = "1"
env["NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING"] = "1"
env["PYTHONFAULTHANDLER"] = "1"

segvcatch = []
if sys.platform.startswith("linux"):
    if shutil.which("catchsegv"):
        segvcatch = ["catchsegv"]
    if env.get("CC"):
        env["CC"] = env["CC"] + " -pthread"
elif sys.platform.startswith("win"):
    env["NUMBA_CPU_NAME"] = "generic"        # avoid LLVM 20 OOM
    env["_NUMBA_REDUCED_TESTING"] = "1"       # reduced Windows test set
    env["PYTHONUTF8"] = "1"                   # numba -s must encode on a piped stdout

# Run from a scratch dir so neither this process nor the numba subprocess holds
# rattler-build's test dir as their CWD.
os.chdir(tempfile.mkdtemp(prefix="numba_run_"))

test_nprocs = env.get("CPU_COUNT", "1")
fast_tests = env.get("FAST_TESTS", "0")
build_platform = env.get("build_platform", "")
target_platform = env.get("target_platform", "")


def run(cmd):
    print("+ " + " ".join(cmd), flush=True)
    subprocess.check_call(cmd, env=env)

run([PY, "-m", "numba.tests.test_runtests"])    # test discovery works

# Disable NumPy AVX512_SKX dispatch when dispatchable and NumPy >= 1.22 (avoids
# low-accuracy SVML libm ufunc loops). Detect in a subprocess so numba is not
# imported into this resident interpreter.
_npy_cmd = (
    "from numba.misc import numba_sysinfo;"
    "s = numba_sysinfo.get_sysinfo();"
    "print('AVX512_SKX' in s.get('NumPy Supported SIMD dispatch', ()) and "
    "s.get('NumPy Version', '0') >= '1.22')"
)
detected = subprocess.check_output([PY, "-c", _npy_cmd], env=env, text=True).strip()
print("NumPy >= 1.22 with AVX512_SKX detected: %s" % detected, flush=True)
if detected == "True":
    env["NPY_DISABLE_CPU_FEATURES"] = "AVX512_SKX"

if build_platform != target_platform:
    random = ["--random=0.08"]
    reason = "Randomizing numba test suite because %s != %s" % (build_platform, target_platform)
elif (target_platform.startswith("win-") or target_platform == "osx-64") and fast_tests == "1":
    random = ["--random=0.5"]
    reason = "Running half the tests except long_running on '%s'" % target_platform
else:
    random = []
    reason = "Running all the tests except long_running on '%s'" % target_platform

print(reason, flush=True)
run(segvcatch + [PY, "-m", "numba.runtests", "-b", *random, "--exclude-tags=long_running", "-m", test_nprocs])

# Diagnostic (print-only): list every process whose executable lives under the
# build tree at end-of-test, so we can see what holds rattler-build's Windows
# test dir (interpreter vs lingering numba workers). No process is killed.
if sys.platform.startswith("win"):
    subprocess.call([
        "powershell.exe", "-NoProfile", "-Command",
        "Get-CimInstance Win32_Process | "
        "Where-Object { $_.ExecutablePath -like 'D:\\bld\\*' } | "
        "ForEach-Object { Write-Host ('HOLDER ' + $_.ProcessId + ' ' + $_.Name + ' :: ' "
        "+ $_.ExecutablePath + ' :: ' + $_.CommandLine) }"
    ])
