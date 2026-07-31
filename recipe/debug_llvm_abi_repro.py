"""Numba-free isolation probe for the LLVM PPC64LE ABI-lowering bug
underlying numba/numba#8489. Builds raw LLVM IR (no numba) for a function
with a (double, i32) signature calling an extern function of the same
shape, to check whether LLVM's PPC64LE backend correctly places the i32
argument in r3 (per the real ELFv2 ABI, where a preceding double does NOT
consume a GPR slot) or incorrectly shifts it to r4.

Remove once the upstream LLVM report is filed and confirmed.
"""
import platform

import llvmlite.binding as llvm
import llvmlite.ir as ir

print("=== debug_llvm_abi_repro: machine", platform.machine(), "===")

double_ty = ir.DoubleType()
i32_ty = ir.IntType(32)

module = ir.Module(name="abi_repro")

foo_ty = ir.FunctionType(double_ty, [double_ty, i32_ty])
foo = ir.Function(module, foo_ty, name="foo")

caller_ty = ir.FunctionType(double_ty, [double_ty, i32_ty])
caller = ir.Function(module, caller_ty, name="caller")
block = caller.append_basic_block(name="entry")
builder = ir.IRBuilder(block)
x, e = caller.args
result = builder.call(foo, [x, e])
builder.ret(result)

print("=== ABI repro LLVM IR ===")
print(str(module))

llvm_mod = llvm.parse_assembly(str(module))
llvm_mod.verify()

llvm.initialize()
llvm.initialize_native_target()
llvm.initialize_native_asmprinter()

target = llvm.Target.from_default_triple()
print("=== target triple ===")
print(target.triple)
tm = target.create_target_machine(opt=2)
asm = tm.emit_assembly(llvm_mod)
print("=== ABI repro NATIVE ASM ===")
print(asm)

print("=== debug_llvm_abi_repro: done ===")
