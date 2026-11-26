[BITS 16]
[ORG 0x8000]

kernel_entry_16:
    cli                     ; Disable interrupts before switching CPU modes
    lgdt [gdt_descriptor]   ; Load Global Descriptor Table

    ; Set PE (Protection Enable) bit in CR0
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; Far jump flushes CPU pipeline and loads 32-bit code segment (0x08)
    jmp 0x08:init_32

; --- Minimal Flat 32-Bit GDT ---
gdt_start:
    dq 0x0000000000000000   ; Null descriptor (required)

gdt_code:                   ; Selector 0x08: Base=0, Limit=4GB, Executable/Readable
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00

gdt_data:                   ; Selector 0x10: Base=0, Limit=4GB, Read/Write
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

; 32-Bit Protected Mode Kernel
[BITS 32]
init_32:
    mov ax, 0x10            ; Load data segment selector (0x10) into all data segments
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000        ; Set stack pointer at 576 KB mark

    cld                     ; Clear direction flag so string ops go forward

    call clear_screen

    mov esi, msg_kernel
    call print_string
    call newline

    mov esi, msg_os1
    call print_string
    call newline

    mov esi, msg_os2
    call print_string
    call newline

    call pic_remap
    call idt_init
    sti                     ; Enable interrupts (keyboard now wakes the CPU)

    call print_prompt
    jmp kernel_idle

; --- Console routines ---

; Fill the whole screen with blank cells using vga_attr and reset the cursor
clear_screen:
    mov edi, 0xB8000
    mov ecx, 80 * 25
    mov ah, [vga_attr]
    mov al, ' '
    rep stosw
    mov byte [vga_row], 0
    mov byte [vga_col], 0
    ret

; Print the null-terminated string at ESI at the current cursor
print_string:
    push eax
    push esi
.next:
    lodsb
    test al, al
    jz .done
    call putchar
    jmp .next
.done:
    pop esi
    pop eax
    ret

; Move the cursor to the start of the next line
newline:
    mov al, 10
    jmp putchar

; Print AL at the current cursor, handling '\n', '\r', wrap and scrolling
putchar:
    cmp al, 10              ; '\n'
    je .newline
    cmp al, 13              ; '\r'
    je .cr
    push ebx
    push ecx
    push edi
    mov cl, al              ; Save char
    movzx eax, byte [vga_row]
    imul eax, 80
    movzx ebx, byte [vga_col]
    add eax, ebx
    shl eax, 1              ; 2 bytes per cell
    add eax, 0xB8000
    mov edi, eax
    mov al, cl              ; Restore char
    mov ah, [vga_attr]
    mov [edi], ax
    inc byte [vga_col]
    cmp byte [vga_col], 80
    jb .done
    mov byte [vga_col], 0
    inc byte [vga_row]
    cmp byte [vga_row], 25
    jb .done
    call scroll
    mov byte [vga_row], 24
.done:
    pop edi
    pop ecx
    pop ebx
    ret
.newline:
    mov byte [vga_col], 0
    inc byte [vga_row]
    cmp byte [vga_row], 25
    jb .nl_done
    call scroll
    mov byte [vga_row], 24
.nl_done:
    ret
.cr:
    mov byte [vga_col], 0
    ret

; Scroll the screen up by one row and clear the last row
scroll:
    push eax
    push ecx
    push esi
    push edi
    mov esi, 0xB8000 + 160
    mov edi, 0xB8000
    mov ecx, 24 * 80
    rep movsw
    mov edi, 0xB8000 + 24 * 160
    mov ecx, 80
    mov ah, [vga_attr]
    mov al, ' '
    rep stosw
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; Print EAX as 8 uppercase hex digits
print_hex:
    push eax
    push ebx
    push ecx
    mov ebx, eax
    mov ecx, 8
.loop:
    rol ebx, 4
    mov eax, ebx
    and eax, 0x0F
    mov al, [hex_digits + eax]
    call putchar
    dec ecx
    jnz .loop
    pop ecx
    pop ebx
    pop eax
    ret

; Print EAX as an unsigned decimal number
print_dec:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
    test eax, eax
    jnz .convert
    mov al, '0'
    call putchar
    jmp .done
.convert:
    xor edx, edx
    div ebx
    push edx                ; Save digit
    inc ecx
    test eax, eax
    jnz .convert
.print:
    pop edx
    mov al, dl
    add al, '0'
    call putchar
    dec ecx
    jnz .print
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; --- Input / interrupt routines ---

; Remap the 8259 PIC: master -> 0x20, slave -> 0x28; enable only IRQ1
pic_remap:
    mov al, 0x11            ; ICW1: start init, expect ICW4
    out 0x20, al
    out 0xA0, al
    mov al, 0x20            ; ICW2: master vector offset
    out 0x21, al
    mov al, 0x28            ; ICW2: slave vector offset
    out 0xA1, al
    mov al, 0x04            ; ICW3: slave on master IRQ2
    out 0x21, al
    mov al, 0x02            ; ICW3: slave cascade identity
    out 0xA1, al
    mov al, 0x01            ; ICW4: 8086 mode
    out 0x21, al
    out 0xA1, al
    mov al, 0xFD            ; Mask all master IRQs except IRQ1
    out 0x21, al
    mov al, 0xFF            ; Mask all slave IRQs
    out 0xA1, al
    ret

; Fill the IDT and load it
idt_init:
    mov edi, idt
    mov ecx, 256
    mov eax, isr_default
.fill:
    mov edx, eax
    mov [edi], dx           ; Offset low
    mov word [edi+2], 0x08  ; Code selector
    mov byte [edi+4], 0
    mov byte [edi+5], 0x8E  ; Present, ring 0, 32-bit interrupt gate
    shr edx, 16
    mov [edi+6], dx         ; Offset high
    add edi, 8
    dec ecx
    jnz .fill
    mov edi, idt + 0x21*8   ; Override keyboard vector
    mov eax, isr_keyboard
    mov edx, eax
    mov [edi], dx
    mov word [edi+2], 0x08
    mov byte [edi+4], 0
    mov byte [edi+5], 0x8E
    shr edx, 16
    mov [edi+6], dx
    lidt [idt_descriptor]
    ret

; Generic interrupt stub: acknowledge and return
isr_default:
    pushad
    mov al, 0x20
    out 0x20, al
    out 0xA0, al
    popad
    iretd

; Keyboard interrupt stub (IRQ1)
isr_keyboard:
    pushad
    xor eax, eax
    in al, 0x60             ; Read scancode
    call keyboard_handler
    mov al, 0x20
    out 0x20, al            ; EOI to master PIC
    popad
    iretd

; Handle a scancode in AL
keyboard_handler:
    cmp al, 0x80
    jae .release
    cmp al, 0x2A            ; Left shift
    je .shift_on
    cmp al, 0x36            ; Right shift
    je .shift_on
    cmp al, 0x1C            ; Enter
    je .enter
    cmp al, 0x0E            ; Backspace
    je .backspace
    movzx eax, al
    mov bl, [shift_state]
    test bl, bl
    jnz .shifted
    mov al, [scancode_table + eax]
    jmp .have_char
.shifted:
    mov al, [scancode_table_shift + eax]
.have_char:
    test al, al
    jz .done
    mov bl, [cmd_len]
    cmp bl, 63
    jae .done
    movzx ecx, bl
    mov [cmd_buf + ecx], al
    inc byte [cmd_len]
    call putchar
    jmp .done
.enter:
    mov al, 10
    call putchar
    movzx ecx, byte [cmd_len]
    mov byte [cmd_buf + ecx], 0
    call process_command
    mov byte [cmd_len], 0
    call print_prompt
    jmp .done
.backspace:
    mov bl, [cmd_len]
    test bl, bl
    jz .done
    dec byte [cmd_len]
    call erase_last_char
    jmp .done
.shift_on:
    mov byte [shift_state], 1
    jmp .done
.release:
    cmp al, 0xAA            ; Left shift release
    je .shift_off
    cmp al, 0xB6            ; Right shift release
    je .shift_off
    jmp .done
.shift_off:
    mov byte [shift_state], 0
.done:
    ret

; Erase the character before the cursor
erase_last_char:
    cmp byte [vga_col], 0
    jne .same_row
    cmp byte [vga_row], 0
    je .done
    dec byte [vga_row]
    mov byte [vga_col], 79
    jmp .write
.same_row:
    dec byte [vga_col]
.write:
    movzx eax, byte [vga_row]
    imul eax, 80
    movzx ebx, byte [vga_col]
    add eax, ebx
    shl eax, 1
    add eax, 0xB8000
    mov edi, eax
    mov ah, [vga_attr]
    mov al, ' '
    mov [edi], ax
.done:
    ret

; Print the command prompt
print_prompt:
    mov esi, msg_prompt
    jmp print_string

; Dispatch the command in cmd_buf
process_command:
    cmp byte [cmd_len], 0
    je .done
    mov esi, cmd_buf
    mov edi, cmd_menu_lit
    call str_eq_ci
    test al, al
    jnz .menu
    mov esi, cmd_buf
    mov edi, cmd_version_lit
    call str_eq_ci
    test al, al
    jnz .version
    mov esi, cmd_buf
    mov edi, cmd_credits_lit
    call str_eq_ci
    test al, al
    jnz .credits
    mov esi, msg_unknown
    call print_string
    jmp .done
.menu:
    mov esi, msg_menu
    call print_string
    jmp .done
.version:
    mov esi, msg_version
    call print_string
    jmp .done
.credits:
    mov esi, msg_credits
    call print_string
.done:
    ret

; Compare ESI and EDI ignoring ASCII case; AL = 1 if equal, else 0
str_eq_ci:
.loop:
    mov al, [esi]
    mov bl, [edi]
    cmp al, 'A'
    jb .l1
    cmp al, 'Z'
    ja .l1
    add al, 32
.l1:
    cmp bl, 'A'
    jb .l2
    cmp bl, 'Z'
    ja .l2
    add bl, 32
.l2:
    cmp al, bl
    jne .no
    test al, al
    jz .yes
    inc esi
    inc edi
    jmp .loop
.yes:
    mov al, 1
    ret
.no:
    xor al, al
    ret

kernel_idle:
    hlt                     ; Wait for hardware interrupts (timer/keyboard)
    jmp kernel_idle

; Console state and strings
vga_row    db 0
vga_col    db 0
vga_attr   db 0x0F          ; White text on black background
hex_digits db "0123456789ABCDEF"

shift_state db 0
cmd_buf     times 64 db 0
cmd_len     db 0

;  Interrupt Descriptor Table 
idt:
    times 256*8 db 0
idt_descriptor:
    dw 256*8 - 1
    dd idt

;  Scancode set 1 -> ASCII tables (0 = not printable) 
scancode_table:
    db 0, 0, '1','2','3','4','5','6','7','8','9','0','-','=', 0, 0
    db 'q','w','e','r','t','y','u','i','o','p','[',']', 0, 0, 'a','s'
    db 'd','f','g','h','j','k','l',';', 0x27, 0x60, 0, 0x5C, 'z','x','c','v'
    db 'b','n','m',',','.','/', 0, 0, 0, ' ', 0, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, '7','8','9','-','4','5','6','+','1'
    db '2','3','0','.', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    times 16 db 0
    times 16 db 0

scancode_table_shift:
    db 0, 0, '!','@','#','$','%','^','&','*','(',')','_','+', 0, 0
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}', 0, 0, 'A','S'
    db 'D','F','G','H','J','K','L',':', 0x22, '~', 0, '|', 'Z','X','C','V'
    db 'B','N','M','<','>','?', 0, 0, 0, ' ', 0, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, '7','8','9','-','4','5','6','+','1'
    db '2','3','0','.', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    times 16 db 0
    times 16 db 0

; --- Messages ---
msg_kernel db "[Kernel Online: 32-bit Protected Mode]", 0
msg_os1 db "Buddysoft BuddyOS [Version 1.000]", 0
msg_os2 db "Buddysoft Corporation. All rights reserved.", 0

msg_prompt db "C:\User> ", 0
msg_unknown db "Unknown command", 10, 0

cmd_menu_lit db "menu", 0
cmd_version_lit db "version", 0
cmd_credits_lit db "credits", 0

msg_menu db "=== MENU ===", 10
         db "1. Buddy Memory Management", 10
         db "2. Interrupt Driven IO Management", 10
         db "3. IPC Message Passing", 10
         db "(options not yet implemented)", 10, 0

msg_version db "Version 1.000 (build 2026)", 10, 0

msg_credits db "=== CREDITS ===", 10
            db "Brylle Cortes (Leader)", 10
            db "Aaron James Monte Siat", 10
            db "Reuel Matthew Arcilla", 10
            db "Vince Nino Colina", 10
            db "CPE 3106", 10, 0

; Pad kernel to exactly 8192 bytes (16 sectors) so INT 13h reads cleanly
times 8192 - ($ - $$) db 0
