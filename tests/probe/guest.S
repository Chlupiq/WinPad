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
        mov     r13d, 1                 # r13: number of the check running; 6 = all passed
        cmp     r12, 504000
        jne     done

        # 2: integer multiply, divide, shifts, flags
        mov     rax, 0x123456789
        mov     rcx, 1000003
        mul     rcx                     # rdx:rax = 0x123456789 * 1000003
        mov     r8, rax
        div     rcx                     # back to 0x123456789, remainder 0
        inc     r13d
        mov     r9, 0x123456789
        cmp     rax, r9
        jne     done
        test    rdx, rdx
        jnz     done
        mov     rax, -7
        cqo
        mov     rcx, 2
        idiv    rcx                     # -3 remainder -1
        cmp     rax, -3
        jne     done
        cmp     rdx, -1
        jne     done
        mov     eax, 0x80000000
        sar     eax, 31                 # 0xffffffff
        shl     rax, 4                  # upper half was cleared: 0xffffffff0
        mov     r9, 0xffffffff0
        cmp     rax, r9
        jne     done
        xor     ecx, ecx
        cmp     r8, 0
        setne   cl
        mov     edx, 5
        cmovz   edx, ecx
        cmp     edx, 5
        jne     done

        # 3: SSE2 scalar and packed
        inc     r13d
        movsd   xmm0, qword ptr [rip + two]
        sqrtsd  xmm1, xmm0
        mulsd   xmm1, xmm1              # ~2.0
        subsd   xmm1, xmm0
        andpd   xmm1, xmmword ptr [rip + absmask]
        comisd  xmm1, qword ptr [rip + epsilon]
        jae     done
        mov     eax, 1234567
        cvtsi2sd xmm2, eax
        mulsd   xmm2, qword ptr [rip + two]
        cvttsd2si eax, xmm2
        cmp     eax, 2469134
        jne     done
        movdqa  xmm3, xmmword ptr [rip + ints]       # 1, 2, 3, 4
        pshufd  xmm4, xmm3, 0x1b                      # 4, 3, 2, 1
        paddd   xmm3, xmm4                            # 5, 5, 5, 5
        pcmpeqd xmm3, xmmword ptr [rip + fives]
        pmovmskb eax, xmm3
        cmp     eax, 0xffff
        jne     done

        # 4: x87
        inc     r13d
        sub     rsp, 16
        fldpi
        mov     dword ptr [rsp], 1000
        fimul   dword ptr [rsp]         # 3141.59...
        fistp   dword ptr [rsp]         # rounds to nearest: 3142
        cmp     dword ptr [rsp], 3142
        jne     x87_done
        fld     qword ptr [rip + two]
        fsqrt
        mov     dword ptr [rsp], 1000000
        fimul   dword ptr [rsp]         # 1414213.56...
        fistp   dword ptr [rsp]
        cmp     dword ptr [rsp], 1414214
        jne     x87_done
        fld1
        fld1
        faddp   st(1), st               # 2
        fld     qword ptr [rip + two]
        fcomip  st, st(1)               # 2 == 2: ZF=1
        fstp    st(0)
        jne     x87_done
        inc     r13d                    # passed: 5
x87_done:
        add     rsp, 16
        cmp     r13d, 5
        jne     done

        # 6: string instructions on the stack
        inc     r13d
        sub     rsp, 16
        lea     rsi, [rip + msg]
        mov     rdi, rsp
        mov     ecx, 3
        cld
        rep movsb
        lea     rsi, [rip + msg]
        mov     rdi, rsp
        mov     ecx, 3
        repe cmpsb
        add     rsp, 16
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
        .p2align 4
absmask:
        .quad   0x7fffffffffffffff, 0x7fffffffffffffff
ints:
        .long   1, 2, 3, 4
fives:
        .long   5, 5, 5, 5
two:
        .double 2.0
epsilon:
        .double 1e-12
