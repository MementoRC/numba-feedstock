"""Temporary debug probe for numba/numba#8489 (ldexp miscompile on ppc64le).

Wired into run_test.sh (ppc64le-only) so it runs inside the real cross/QEMU
test environment instead of the full randomized numba.runtests suite.
Remove once the root cause is confirmed and a fix/skip lands.
"""
import math
import platform
import sys

import llvmlite
import numba
from numba import njit

print("=== debug_ldexp: numba", numba.__version__, "llvmlite", llvmlite.__version__,
      "machine", platform.machine(), "===")


def ldexp1(x, e):
    return math.ldexp(x, e)


cfunc = njit(cache=False)(ldexp1)
x, e = 2.5, -2
try:
    result = cfunc(x, e)
    expected = ldexp1(x, e)
    match = "MATCH" if result == expected else "MISMATCH"
    print("RESULT", result, "EXPECTED", expected, match)

    for sig, ir in cfunc.inspect_llvm().items():
        print("=== LLVM IR", sig, "===")
        print(ir)

    for sig, asm in cfunc.inspect_asm().items():
        print("=== NATIVE ASM", sig, "===")
        print(asm)
except Exception as exc:  # never fail the build over the debug probe
    print("debug_ldexp probe raised:", repr(exc), file=sys.stderr)

print("=== debug_ldexp: done ===")
