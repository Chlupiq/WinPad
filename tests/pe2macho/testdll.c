// SPDX-License-Identifier: MIT
// A small ARM64 Windows DLL for tests/pe2macho: code that reaches its data
// PC-relatively, and pointers in data that need base relocations.
static int counter = 5;
static const char text[] = "hello from a PE image";

// Base relocations (IMAGE_REL_BASED_DIR64): pe2macho turns them into Mach-O
// rebases, so they point into the dylib.
int* counter_ptr = &counter;
const char* greeting = text;

__declspec(dllexport) int pe_add_mul(int a, int b) {
  counter += a;
  return a * b + *counter_ptr;
}

__declspec(dllexport) const char* pe_greeting(void) {
  return greeting;
}

__declspec(dllexport) int pe_counter(void) {
  return counter;
}

// TEB reads through x18, as Windows code does (NtCurrentTeb(), GetLastError
// and friends). Darwin zeroes x18, so pe2macho rewrites these instructions
// into branches to trampolines that load the TEB from a TSD slot. One form of
// each kind the rewrite handles: load and store with an immediate offset, a
// register offset, MOV, ADD immediate and STP of x18 itself.
__declspec(dllexport) __attribute__((naked)) unsigned long long pe_teb_self(void) {
  __asm__("ldr x0, [x18, #0x30]\n\tret");  // NtCurrentTeb()->Tib.Self
}

__declspec(dllexport) __attribute__((naked)) void pe_set_last_error(unsigned int code) {
  __asm__("str w0, [x18, #0x68]\n\tret");  // TEB->LastErrorValue
}

__declspec(dllexport) __attribute__((naked)) unsigned int pe_last_error(void) {
  __asm__("mov x1, #0x68\n\tldr w0, [x18, x1]\n\tret");
}

__declspec(dllexport) __attribute__((naked)) unsigned long long pe_teb(void) {
  __asm__("mov x0, x18\n\tret");
}

__declspec(dllexport) __attribute__((naked)) unsigned long long pe_last_error_addr(void) {
  __asm__("add x0, x18, #0x68\n\tret");
}

__declspec(dllexport) __attribute__((naked)) void pe_store_teb_pair(unsigned long long* out) {
  __asm__("stp x17, x18, [x0]\n\tret");
}
