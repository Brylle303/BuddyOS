; =====================================================================
; constants.inc - Part 3 (interrupt-driven I/O) shared constants
; Included once, at the top of kernel.asm.
; =====================================================================
SEL_CODE        equ 0x08            ; flat code selector (kernel.asm GDT)
SEL_DATA        equ 0x10            ; flat data selector

IDT_ENTRIES     equ 256
IDT_INT_GATE    equ 0x8E            ; present, ring 0, 32-bit interrupt gate (IF cleared)

PIC1_CMD        equ 0x20
PIC1_DATA       equ 0x21
PIC2_CMD        equ 0xA0
PIC2_DATA       equ 0xA1
PIC_EOI         equ 0x20
IRQ_BASE        equ 32              ; IRQ0-15 -> vectors 32-47

PIT_CH0         equ 0x40
PIT_CMD         equ 0x43
PIT_BASE_HZ     equ 1193182
TIMER_HZ        equ 100             ; 10 ms per tick
PIT_DIVISOR     equ PIT_BASE_HZ / TIMER_HZ

KBD_DATA        equ 0x60
KBD_STATUS      equ 0x64
KBD_BUF_SIZE    equ 64              ; must be a power of two

; Interrupt frame offsets (see isr_common in isr.asm)
F_ES            equ 0
F_DS            equ 4
F_EDI           equ 8
F_ESI           equ 12
F_EBP           equ 16
F_ESP           equ 20
F_EBX           equ 24
F_EDX           equ 28
F_ECX           equ 32
F_EAX           equ 36
F_VECTOR        equ 40
F_ERRCODE       equ 44
F_EIP           equ 48
F_CS            equ 52
F_EFLAGS        equ 56
