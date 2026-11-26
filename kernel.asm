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

    ; Demo of the number helpers
    call newline
    mov eax, 0xDEADBEEF
    call print_hex
    call newline
    mov eax, 12345
    call print_dec

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

kernel_idle:
    hlt                     ; Wait for hardware interrupts (timer/keyboard)
    jmp kernel_idle

; --- Console state and strings ---
vga_row    db 0
vga_col    db 0
vga_attr   db 0x0A          ; Light green text on black background
hex_digits db "0123456789ABCDEF"

msg_kernel db "[Kernel Online: 32-bit Protected Mode]", 0
msg_os1 db "Buddysoft BuddyOS [Version 1.000]", 0
msg_os2 db "Buddysoft Corporation. All rights reserved.", 0

; Pad kernel to exactly 4096 bytes (8 sectors) so INT 13h reads cleanly
times 4096 - ($ - $$) db 0
