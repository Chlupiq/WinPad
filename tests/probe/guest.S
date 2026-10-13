# x86-64 test program for the probe frontend. Unlike tests/fex-cache/guest.S
# it is position independent and lives in one section: the probe maps the raw
# bytes anywhere (iOS reserves the low 4 GB), so nothing may need relocating.
# The call table holds offsets, not addresses.
        .intel_syntax noprefix
        .text
        .globl _start
_start:
        xor     r12d, r12d              # accumulator
        mov     ebx, 1000               # loop counter
1:
        mov     edi, ebx
        call    add_one
        add     r12, rax
        mov     eax, ebx
        and     eax, 1
        lea     rcx, [rip + table]
        movsxd  rdx, dword ptr [rcx + rax*4]
        add     rdx, rcx
        call    rdx
        add     r12, rax
        dec     ebx
        jnz     1b

        # expected: sum(i+1, i=1..1000) + 500*2 + 500*3 = 501500 + 2500 = 504000
        cmp     r12, 504000
        jne     done
        mov     eax, 1                  # write(1, msg, 3)
        mov     edi, 1
        lea     rsi, [rip + msg]
        mov     edx, 3
        syscall
done:
        hlt                             # the probe runs FEX with exit on HLT

add_one:
        lea     rax, [rdi + 1]
        ret
even:
        mov     eax, 2
        ret
odd:
        mov     eax, 3
        ret

        .p2align 2
table:
        .long   even - table, odd - table
msg:
        .ascii  "ok\n"
