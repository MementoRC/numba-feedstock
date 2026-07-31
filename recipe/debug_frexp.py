"""Temporary debug probe checking whether math.frexp shares the PPC64LE
LLVM ABI-lowering bug confirmed for math.ldexp (numba/numba#8489, see
debug_ldexp.py). numba_frexp(double x, int *exp) in _helperlib.c has the
same (double, then-GPR-slot-arg) shape as numba_ldexp(double x, int exp) --
except the second argument is a pointer that gets WRITTEN THROUGH, so a
GPR-shadowing miscompile here risks a wild-pointer write, not just a wrong
number.

Wired into run_test.sh (ppc64le-only) so it runs inside the real cross/QEMU
test environment instead of the full randomized numba.runtests suite.
Remove once the frexp exposure is confirmed/ruled out and a fix/skip lands.
"""
import math
import platform
import sys

import llvmlite
import numba
from numba import njit

print("=== debug_frexp: numba", numba.__version__, "llvmlite", llvmlite.__version__,
      "machine", platform.machine(), "===")


def frexp1(x):
    return math.frexp(x)


cfunc = njit(cache=False)(frexp1)
x = 2.5
try:
    result = cfunc(x)
    expected = frexp1(x)
    match = "MATCH" if result == expected else "MISMATCH"
    print("RESULT", result, "EXPECTED", expected, match)

    for sig, ir in cfunc.inspect_llvm().items():
        print("=== LLVM IR", sig, "===")
        print(ir)

    for sig, asm in cfunc.inspect_asm().items():
        print("=== NATIVE ASM", sig, "===")
        print(asm)
except Exception as exc:  # never fail the build over the debug probe
    print("debug_frexp probe raised:", repr(exc), file=sys.stderr)

print("=== debug_frexp: done ===")
