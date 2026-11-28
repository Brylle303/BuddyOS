; =====================================================================
; pic.asm - Requirement #14: PIC remapping, mask/unmask, EOI
; IRQ0-7 -> vectors 32-39, IRQ8-15 -> vectors 40-47
; =====================================================================
pic_io_wait:
    out 0x80, al                    ; unused port = short delay
    ret

; pic_remap: remap, then mask everything except the cascade (IRQ2).
; Drivers unmask their own IRQ through irq_register. Clobbers EAX.
pic_remap:
    mov al, 0x11                    ; ICW1: init, expect ICW4
    out PIC1_CMD, al
    call pic_io_wait
    out PIC2_CMD, al
    call pic_io_wait
    mov al, IRQ_BASE                ; ICW2: master offset
    out PIC1_DATA, al
    call pic_io_wait
    mov al, IRQ_BASE + 8            ; ICW2: slave offset
    out PIC2_DATA, al
    call pic_io_wait
    mov al, 0x04                    ; ICW3: slave on IRQ2
    out PIC1_DATA, al
    call pic_io_wait
    mov al, 0x02                    ; ICW3: cascade identity
    out PIC2_DATA, al
    call pic_io_wait
    mov al, 0x01                    ; ICW4: 8086 mode
    out PIC1_DATA, al
    call pic_io_wait
    out PIC2_DATA, al
    call pic_io_wait
    mov al, 0xFB                    ; master: only IRQ2 open
    out PIC1_DATA, al
    mov al, 0xFF                    ; slave: all masked
    out PIC2_DATA, al
    ret

; pic_unmask_irq: AL = IRQ (0-15). Clobbers EAX.
pic_unmask_irq:
    push ecx
    push edx
    mov cl, al
    mov dx, PIC1_DATA
    cmp cl, 8
    jb .go
    sub cl, 8
    mov dx, PIC2_DATA
.go:
    in al, dx
    mov ah, 1
    shl ah, cl
    not ah
    and al, ah
    out dx, al
    pop edx
    pop ecx
    ret

; pic_mask_irq: AL = IRQ (0-15). Clobbers EAX.
pic_mask_irq:
    push ecx
    push edx
    mov cl, al
    mov dx, PIC1_DATA
    cmp cl, 8
    jb .go
    sub cl, 8
    mov dx, PIC2_DATA
.go:
    in al, dx
    mov ah, 1
    shl ah, cl
    or al, ah
    out dx, al
    pop edx
    pop ecx
    ret

; pic_send_eoi: AL = IRQ. IRQ 8-15 need EOI on slave and master.
pic_send_eoi:
    push eax
    cmp al, 8
    jb .master
    mov al, PIC_EOI
    out PIC2_CMD, al
.master:
    mov al, PIC_EOI
    out PIC1_CMD, al
    pop eax
    ret

; pic_read_isr: AX = (slave ISR << 8) | master ISR (spurious IRQ detection)
pic_read_isr:
    mov al, 0x0B
    out PIC1_CMD, al
    out PIC2_CMD, al
    in al, PIC2_CMD
    mov ah, al
    in al, PIC1_CMD
    ret
