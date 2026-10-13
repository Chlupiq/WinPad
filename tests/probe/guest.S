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
        lea     rsp, [rsp + 16]         # keeps the flags of cmpsb
        jne     done

        # 7-9: exceptions reach the handler the guest registered with the
        # probe, which gets rdi = trap number, rsi = rip, rdx = fault address
        # and checks them against r8, r9, r10, then continues at r15.
        mov     eax, 0x5750             # probe: set the exception handler
        lea     rdi, [rip + on_exception]
        syscall
        inc     r13d                    # 7: ud2, #UD at the instruction
        mov     r8d, 6
        lea     r9, [rip + ud2_at]
        xor     r10d, r10d
        lea     r15, [rip + after_ud2]
ud2_at:
        ud2
after_ud2:
        inc     r13d                    # 8: int3, #BP after the instruction
        mov     r8d, 3
        lea     r9, [rip + after_int3]
        lea     r15, [rip + after_int3]
        int3
after_int3:
        inc     r13d                    # 9: read from a null pointer, #PF
        mov     r8d, 14
        lea     r9, [rip + load_at]
        mov     r10d, 0x18
        lea     r15, [rip + after_load]
load_at:
        mov     rax, qword ptr [r10]
        jmp     done                    # the read did not fault
after_load:

        # 10: threads. Two guest threads and this one each add 1 to a counter
        # on this stack 100000 times with lock inc; the probe runs the guest
        # threads on host threads (syscall 0x5751 start, 0x5752 wait).
        inc     r13d
        sub     rsp, 16
        mov     qword ptr [rsp], 0
        mov     eax, 0x5751
        lea     rdi, [rip + worker]
        lea     rsi, [rsp - 0x40000]    # its stack: further down this one
        mov     rdx, rsp                # its rdi: the counter
        syscall
        mov     r14, rax
        mov     eax, 0x5751
        lea     rdi, [rip + worker]
        lea     rsi, [rsp - 0x80000]
        mov     rdx, rsp
        syscall
        mov     r15, rax
        mov     rdi, rsp
        call    count
        mov     eax, 0x5752
        mov     rdi, r14
        syscall
        test    rax, rax
        jnz     done
        mov     eax, 0x5752
        mov     rdi, r15
        syscall
        test    rax, rax
        jnz     done
        cmp     qword ptr [rsp], 300000
        lea     rsp, [rsp + 16]
        jne     done

        mov     eax, 1                  # write(1, msg, 3)
        mov     edi, 1
        lea     rsi, [rip + msg]
        mov     edx, 3
        syscall
done:
        hlt                             # the probe runs FEX with exit on HLT

worker:
        call    count
        hlt                             # stops this thread only

count:
        mov     ecx, 100000
1:
        lock inc qword ptr [rdi]
        dec     ecx
        jnz     1b
        ret

on_exception:
        cmp     rdi, r8
        jne     done
        cmp     rsi, r9
        jne     done
        cmp     rdx, r10
        jne     done
        jmp     r15

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
