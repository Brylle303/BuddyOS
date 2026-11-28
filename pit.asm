; =====================================================================
; pit.asm - Requirement #16: timer driver (PIT channel 0, IRQ0)
; 100 Hz tick, 32-bit tick counter, hook for the future scheduler.
; =====================================================================
pit_init:
    mov al, 0x34                    ; ch0, lobyte/hibyte, mode 2, binary
    out PIT_CMD, al
    mov al, PIT_DIVISOR & 0xFF
    out PIT_CH0, al
    mov al, (PIT_DIVISOR >> 8) & 0xFF
    out PIT_CH0, al
    mov dword [tick_count], 0
    mov dword [sched_hook], 0
    xor eax, eax                    ; IRQ0
    mov ebx, pit_irq_handler
    call irq_register
    ret

; pit_irq_handler: ISR context, keep it short.
pit_irq_handler:
    inc dword [tick_count]
    mov eax, [sched_hook]           ; scheduler installs itself here later
    test eax, eax
    jz .done
    call eax
.done:
    ret

; pit_sleep_ticks: EAX = ticks to wait. Needs interrupts enabled.
pit_sleep_ticks:
    push ebx
    mov ebx, [tick_count]
    add ebx, eax
.wait:
    hlt
    mov eax, [tick_count]
    sub eax, ebx                    ; wrap-safe compare
    js .wait
    pop ebx
    ret

tick_count: dd 0
sched_hook: dd 0
