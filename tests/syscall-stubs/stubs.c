#include "wine/asm.h"
void *__wine_syscall_dispatcher = 0;
__ASM_SYSCALL_FUNC( 0x0004, NtWaitForSingleObject )
__ASM_SYSCALL_FUNC( 0x000e, NtSetEvent )
int __cdecl DllMainCRTStartup(void *a, unsigned b, void *c) { return 1; }
