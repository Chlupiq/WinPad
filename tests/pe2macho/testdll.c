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
