# Small static x86-64 Linux program for FEX code-cache tests.
# Direct calls, a loop, an indirect call through a table and a conditional
# branch give FEX several kinds of block exits to link.
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
        call    qword ptr [rcx + rax*8]
        add     r12, rax
        dec     ebx
        jnz     1b

        # expected: sum(i+1, i=1..1000) + 500*2 + 500*3 = 501500 + 2500 = 504000
        cmp     r12, 504000
        jne     fail
        mov     eax, 1                  # write(1, msg, 3)
        mov     edi, 1
        lea     rsi, [rip + msg]
        mov     edx, 3
        syscall
        xor     edi, edi
        jmp     exit
fail:
        mov     edi, 1
exit:
        mov     eax, 231                # exit_group, so FEX shuts down as for a normal process exit
        syscall

add_one:
        lea     rax, [rdi + 1]
        ret
even:
        mov     eax, 2
        ret
odd:
        mov     eax, 3
        ret

        .section .data.rel.ro,"aw"
table:
        .quad   even, odd
        .section .rodata
msg:
        .ascii  "ok\n"
