; =====================================================================
; isr.asm - Requirements #13 (exception handlers) and #15 (ISR stubs)
;
; Every vector enters isr_common, which builds this frame:
;   +0 es  +4 ds  +8 edi +12 esi +16 ebp +20 esp(dummy)
;   +24 ebx +28 edx +32 ecx +36 eax
;   +40 vector  +44 error code (0 when the CPU pushes none)
;   +48 eip  +52 cs  +56 eflags
;
; Handler rules: called with interrupts OFF, may clobber any register
; except EBP/ESP/segments, must not call buddy_alloc / buddy_free.
; =====================================================================

%macro ISR_NOERR 1
isr_stub_%1:
    push dword 0                    ; fake error code keeps the frame uniform
    push dword %1
    jmp isr_common
%endmacro

%macro ISR_ERR 1
isr_stub_%1:                        ; CPU already pushed the error code
    push dword %1
    jmp isr_common
%endmacro

%macro IRQ_STUB 1
irq_stub_%1:
    push dword 0
    push dword (IRQ_BASE + %1)
    jmp isr_common
%endmacro

; ---- CPU exceptions 0-31 ----
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_NOERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_ERR   30
ISR_NOERR 31

; ---- Hardware IRQs 0-15 (vectors 32-47) ----
IRQ_STUB 0
IRQ_STUB 1
IRQ_STUB 2
IRQ_STUB 3
IRQ_STUB 4
IRQ_STUB 5
IRQ_STUB 6
IRQ_STUB 7
IRQ_STUB 8
IRQ_STUB 9
IRQ_STUB 10
IRQ_STUB 11
IRQ_STUB 12
IRQ_STUB 13
IRQ_STUB 14
IRQ_STUB 15

; ---- Every other vector (48-255) ----
isr_default_stub:
    push dword 0
    push dword 255
    jmp isr_common

; isr_common: save state, dispatch, restore, IRETD
isr_common:
    pushad
    push ds
    push es
    mov ax, SEL_DATA
    mov ds, ax
    mov es, ax
    cld
    push esp                        ; argument: pointer to the frame
    call isr_dispatch
    add esp, 4
    pop es
    pop ds
    popad
    add esp, 8                      ; drop vector + error code
    iretd

; isr_dispatch(frame)  [cdecl, frame at [ebp+8]]
isr_dispatch:
    push ebp
    mov ebp, esp
    sub esp, 4                      ; [ebp-4] = IRQ number
    mov esi, [ebp + 8]
    mov eax, [esi + F_VECTOR]
    cmp eax, IRQ_BASE
    jb .exception
    cmp eax, IRQ_BASE + 16
    jae .unhandled

    sub eax, IRQ_BASE
    mov [ebp - 4], eax
    cmp eax, 7
    jne .check15
    call pic_read_isr               ; spurious IRQ7: ISR bit 7 clear
    test al, 0x80
    jz .spurious
    jmp .dispatch
.check15:
    cmp eax, 15
    jne .dispatch
    call pic_read_isr               ; spurious IRQ15: ISR bit 15 clear
    test ah, 0x80
    jnz .dispatch
    mov al, PIC_EOI                 ; master still needs its EOI (cascade)
    out PIC1_CMD, al
.spurious:
    inc dword [spurious_count]
    jmp .done

.dispatch:
    mov eax, [ebp - 4]
    inc dword [irq_counts + eax*4]
    mov ebx, [irq_handlers + eax*4]
    test ebx, ebx
    jz .eoi
    call ebx                        ; the registered IRQ handler
.eoi:
    mov eax, [ebp - 4]
    call pic_send_eoi
    jmp .done

.exception:
    push esi
    call exception_handler
    add esp, 4
    jmp .done

.unhandled:
    inc dword [unhandled_count]
.done:
    mov esp, ebp
    pop ebp
    ret

; irq_register: EAX = IRQ (0-15), EBX = handler. Also unmasks the IRQ.
irq_register:
    mov [irq_handlers + eax*4], ebx
    call pic_unmask_irq
    ret

; irq_unregister: EAX = IRQ. Masks it and clears the handler.
irq_unregister:
    push eax
    call pic_mask_irq
    pop eax
    mov dword [irq_handlers + eax*4], 0
    ret

; print_kv: ESI = label, EAX = value -> "label0x########"
print_kv:
    call kputs
    call kputhex
    ret

; exception_handler(frame): print diagnostics, then halt.
; #BP (INT3) is reported and execution continues.
exception_handler:
    push ebp
    mov ebp, esp
    mov edi, [ebp + 8]

    cmp dword [edi + F_VECTOR], 3
    jne .fatal
    mov esi, str_bp
    mov eax, [edi + F_EIP]
    call print_kv
    call newline
    pop ebp
    ret

.fatal:
    mov esi, str_exc_hdr
    call kputs
    mov eax, [edi + F_VECTOR]
    mov esi, [exc_names + eax*4]
    call kputs
    call newline

    mov esi, str_vec
    mov eax, [edi + F_VECTOR]
    call print_kv
    mov esi, str_err
    mov eax, [edi + F_ERRCODE]
    call print_kv
    call newline
    mov esi, str_eip
    mov eax, [edi + F_EIP]
    call print_kv
    mov esi, str_cs
    mov eax, [edi + F_CS]
    call print_kv
    call newline
    mov esi, str_efl
    mov eax, [edi + F_EFLAGS]
    call print_kv
    cmp dword [edi + F_VECTOR], 14
    jne .halt
    mov esi, str_cr2
    mov eax, cr2                    ; faulting address (page faults)
    call print_kv
.halt:
    call newline
    mov esi, str_halt
    call kputs
    cli
.hang:
    hlt
    jmp .hang

isr_stub_table:
%assign i 0
%rep 32
    dd isr_stub_%+i
%assign i i+1
%endrep

irq_stub_table:
%assign i 0
%rep 16
    dd irq_stub_%+i
%assign i i+1
%endrep

exc_names:
    dd en0,  en1,  en2,  en3,  en4,  en5,  en6,  en7
    dd en8,  en9,  en10, en11, en12, en13, en14, en15
    dd en16, en17, en18, en19, en20, en21, en22, en23
    dd en24, en25, en26, en27, en28, en29, en30, en31

en0:  db "Divide Error (#DE)", 0
en1:  db "Debug (#DB)", 0
en2:  db "Non-Maskable Interrupt", 0
en3:  db "Breakpoint (#BP)", 0
en4:  db "Overflow (#OF)", 0
en5:  db "BOUND Range Exceeded (#BR)", 0
en6:  db "Invalid Opcode (#UD)", 0
en7:  db "Device Not Available (#NM)", 0
en8:  db "Double Fault (#DF)", 0
en9:  db "Coprocessor Segment Overrun", 0
en10: db "Invalid TSS (#TS)", 0
en11: db "Segment Not Present (#NP)", 0
en12: db "Stack-Segment Fault (#SS)", 0
en13: db "General Protection Fault (#GP)", 0
en14: db "Page Fault (#PF)", 0
en15: db "Reserved", 0
en16: db "x87 FP Error (#MF)", 0
en17: db "Alignment Check (#AC)", 0
en18: db "Machine Check (#MC)", 0
en19: db "SIMD FP Exception (#XM)", 0
en20: db "Reserved", 0
en21: db "Reserved", 0
en22: db "Reserved", 0
en23: db "Reserved", 0
en24: db "Reserved", 0
en25: db "Reserved", 0
en26: db "Reserved", 0
en27: db "Reserved", 0
en28: db "Reserved", 0
en29: db "Reserved", 0
en30: db "Security Exception (#SX)", 0
en31: db "Reserved", 0

str_exc_hdr: db "*** CPU EXCEPTION: ", 0
str_bp:      db "[#BP] breakpoint hit, EIP=", 0
str_vec:     db "  vector=", 0
str_err:     db "  errcode=", 0
str_eip:     db "  EIP=", 0
str_cs:      db "  CS=", 0
str_efl:     db "  EFLAGS=", 0
str_cr2:     db "  CR2=", 0
str_halt:    db "System halted.", 10, 0

irq_handlers:    times 16 dd 0      ; handler per IRQ (0 = none)
irq_counts:      times 16 dd 0      ; how many times each IRQ fired
spurious_count:  dd 0
unhandled_count: dd 0
