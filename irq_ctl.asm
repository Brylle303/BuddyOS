; =====================================================================
; irq_ctl.asm - Requirement #19: interrupt enable/disable control
; Save/restore EFLAGS so critical sections nest correctly
; (buddy.asm uses the same pushfd / cli / popfd pattern).
; =====================================================================
%macro IRQ_SAVE 0
    pushfd
    cli
%endmacro

%macro IRQ_RESTORE 0
    popfd
%endmacro

irq_save:                           ; out: EAX = old EFLAGS, interrupts off
    pushfd
    pop eax
    cli
    ret

irq_restore:                        ; in: EAX = value from irq_save
    push eax
    popfd
    ret
