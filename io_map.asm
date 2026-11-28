; =====================================================================
; io_map.asm - Requirement #18: device I/O map table
; Entry (16 bytes): name ptr | port | IRQ | vector | handler | owner
; owner = task/mailbox id (0 = kernel; filled in by the IPC milestone)
; =====================================================================
IO_MAP_ENTRY_SIZE equ 16

%macro IOMAP 6                      ; name, port, irq, vector, handler, owner
    dd %1
    dw %2
    db %3
    db %4
    dd %5
    dd %6
%endmacro

io_map_table:
    IOMAP iom_pit, 0x40, 0, IRQ_BASE + 0, pit_irq_handler, 0
    IOMAP iom_kbd, 0x60, 1, IRQ_BASE + 1, kbd_irq_handler, 0
IO_MAP_COUNT equ (($ - io_map_table) / IO_MAP_ENTRY_SIZE)

iom_pit: db "PIT timer", 0
iom_kbd: db "Keyboard ", 0
iom_hdr: db "device     port        IRQ vec handler     owner", 10, 0
iom_sp:  db "  ", 0

; io_map_dump: print the whole table (evidence for the report)
io_map_dump:
    pushad
    mov esi, iom_hdr
    call kputs
    mov ebx, io_map_table
    mov ecx, IO_MAP_COUNT
.row:
    mov esi, [ebx]
    call kputs
    mov esi, iom_sp
    call kputs
    movzx eax, word [ebx + 4]
    call kputhex
    call kputs
    movzx eax, byte [ebx + 6]
    call kputdec
    call kputs
    movzx eax, byte [ebx + 7]
    call kputdec
    call kputs
    mov eax, [ebx + 8]
    call kputhex
    call kputs
    mov eax, [ebx + 12]
    call kputdec
    call newline
    add ebx, IO_MAP_ENTRY_SIZE
    dec ecx
    jnz .row
    popad
    ret

; io_map_find_irq: EAX = IRQ -> ESI = entry, or 0 if none
io_map_find_irq:
    push ecx
    mov esi, io_map_table
    mov ecx, IO_MAP_COUNT
.next:
    cmp [esi + 6], al
    je .found
    add esi, IO_MAP_ENTRY_SIZE
    dec ecx
    jnz .next
    xor esi, esi
.found:
    pop ecx
    ret

; io_map_set_owner: EAX = IRQ, EBX = owner id
io_map_set_owner:
    push esi
    call io_map_find_irq
    test esi, esi
    jz .out
    mov [esi + 12], ebx
.out:
    pop esi
    ret
