.syntax unified
.globl _start
.align 2
.code 32
_start:
    ldr r0, [sp]            @ argc
    add r1, sp, #4          @ argv
    add r4, r0, #1
    add r2, r1, r4, lsl #2  @ envp
    bic sp, sp, #7          @ 8-byte stack alignment
    mov r3, r2
1:
    ldr r4, [r3], #4
    cmp r4, #0
    bne 1b                  @ r3 = apple
    bl _main
    b _exit

.globl _memset
.align 2
.code 32
_memset:
    mov r3, r0
1:
    cmp r2, #0
    beq 2f
    strb r1, [r3], #1
    sub r2, r2, #1
    b 1b
2:
    bx lr

.globl _memcpy
.align 2
.code 32
_memcpy:
    mov r3, r0
1:
    cmp r2, #0
    beq 2f
    ldrb r12, [r1], #1
    strb r12, [r3], #1
    sub r2, r2, #1
    b 1b
2:
    bx lr
