; =====================================================================
; idt.asm - Requirement #12: IDT + LIDT
; =====================================================================

; idt_set_gate: EAX = vector, EBX = handler address, DL = gate type.
; Preserves all registers.
idt_set_gate:
    push edi
    push ebx
    lea edi, [idt_table + eax*8]
    mov [edi], bx                   ; offset 15:0
    mov word [edi + 2], SEL_CODE
    mov byte [edi + 4], 0
    mov [edi + 5], dl
    shr ebx, 16
    mov [edi + 6], bx               ; offset 31:16
    pop ebx
    pop edi
    ret

; idt_init: all 256 gates -> default stub, then 32 exceptions and 16 IRQs.
; Clobbers EAX, EBX, ECX, EDX.
idt_init:
    xor ecx, ecx
.default:
    mov eax, ecx
    mov ebx, isr_default_stub
    mov dl, IDT_INT_GATE
    call idt_set_gate
    inc ecx
    cmp ecx, IDT_ENTRIES
    jb .default

    xor ecx, ecx
.exceptions:
    mov eax, ecx
    mov ebx, [isr_stub_table + ecx*4]
    mov dl, IDT_INT_GATE
    call idt_set_gate
    inc ecx
    cmp ecx, 32
    jb .exceptions

    xor ecx, ecx
.irqs:
    lea eax, [ecx + IRQ_BASE]
    mov ebx, [irq_stub_table + ecx*4]
    mov dl, IDT_INT_GATE
    call idt_set_gate
    inc ecx
    cmp ecx, 16
    jb .irqs

    lidt [idt_ptr]
    ret

idt_ptr:
    dw IDT_ENTRIES * 8 - 1
    dd idt_table
idt_table: times IDT_ENTRIES * 8 db 0
