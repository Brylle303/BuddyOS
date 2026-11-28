; =====================================================================
; keyboard.asm - Requirement #17: keyboard driver (IRQ1)
; The ISR only reads the scancode, translates it and pushes the
; character into a circular buffer. The shell (kernel_idle) pops
; characters with kbd_getc. One producer (ISR), one consumer (shell),
; so no lock is needed. Enter = 10, Backspace = 8.
; =====================================================================
kbd_init:
.drain:                             ; flush stale bytes in the controller
    in al, KBD_STATUS
    test al, 1
    jz .drained
    in al, KBD_DATA
    jmp .drain
.drained:
    mov dword [kbd_head], 0
    mov dword [kbd_tail], 0
    mov dword [kbd_overflow], 0
    mov dword [kbd_msg_hook], 0
    mov byte [kbd_shift], 0
    mov byte [kbd_ext], 0
    mov eax, 1                      ; IRQ1
    mov ebx, kbd_irq_handler
    call irq_register
    ret

; kbd_irq_handler: ISR context. Never blocks, never allocates.
kbd_irq_handler:
    in al, KBD_DATA
    cmp al, 0xE0                    ; extended prefix: skip the next byte
    jne .not_ext
    mov byte [kbd_ext], 1
    ret
.not_ext:
    cmp byte [kbd_ext], 0
    je .normal
    mov byte [kbd_ext], 0
    ret
.normal:
    test al, 0x80
    jnz .release
    cmp al, 0x2A                    ; left shift
    je .shift_on
    cmp al, 0x36                    ; right shift
    je .shift_on
    movzx ebx, al
    cmp byte [kbd_shift], 0
    jne .shifted
    mov al, [kbd_map_normal + ebx]
    jmp .have
.shifted:
    mov al, [kbd_map_shift + ebx]
.have:
    test al, al
    jz .done
    call kbd_buf_put
    mov ecx, [kbd_msg_hook]         ; ISR->task message hook (AL = char)
    test ecx, ecx
    jz .done
    call ecx
.done:
    ret
.shift_on:
    mov byte [kbd_shift], 1
    ret
.release:
    and al, 0x7F
    cmp al, 0x2A
    je .shift_off
    cmp al, 0x36
    je .shift_off
    ret
.shift_off:
    mov byte [kbd_shift], 0
    ret

; kbd_buf_put: AL = char. Drops the key (and counts it) if the buffer is full.
kbd_buf_put:
    mov ecx, [kbd_head]
    mov edx, ecx
    inc edx
    and edx, KBD_BUF_SIZE - 1
    cmp edx, [kbd_tail]
    je .full
    mov [kbd_buffer + ecx], al
    mov [kbd_head], edx             ; publish after the byte is stored
    ret
.full:
    inc dword [kbd_overflow]
    ret

; kbd_getc: non-blocking. EAX = char, or 0 if the buffer is empty.
kbd_getc:
    mov edx, [kbd_tail]
    cmp edx, [kbd_head]
    je .empty
    movzx eax, byte [kbd_buffer + edx]
    inc edx
    and edx, KBD_BUF_SIZE - 1
    mov [kbd_tail], edx
    ret
.empty:
    xor eax, eax
    ret

; Scancode set 1 -> ASCII (0 = nothing to buffer)
kbd_map_normal:
    db 0, 0, '1','2','3','4','5','6','7','8','9','0','-','=', 8, 0
    db 'q','w','e','r','t','y','u','i','o','p','[',']', 10, 0, 'a','s'
    db 'd','f','g','h','j','k','l',';', 0x27, 0x60, 0, 0x5C, 'z','x','c','v'
    db 'b','n','m',',','.','/', 0, 0, 0, ' ', 0, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, '7','8','9','-','4','5','6','+','1'
    db '2','3','0','.', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    times 32 db 0
kbd_map_shift:
    db 0, 0, '!','@','#','$','%','^','&','*','(',')','_','+', 8, 0
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}', 10, 0, 'A','S'
    db 'D','F','G','H','J','K','L',':', 0x22, '~', 0, '|', 'Z','X','C','V'
    db 'B','N','M','<','>','?', 0, 0, 0, ' ', 0, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, '7','8','9','-','4','5','6','+','1'
    db '2','3','0','.', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    times 32 db 0
%if ($ - kbd_map_shift) != 128
%error "scancode tables must have 128 entries"
%endif

kbd_head:     dd 0
kbd_tail:     dd 0
kbd_overflow: dd 0
kbd_msg_hook: dd 0                  ; Milestone 12: post a message to the shell
kbd_shift:    db 0
kbd_ext:      db 0
kbd_buffer:   times KBD_BUF_SIZE db 0
