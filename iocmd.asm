; =====================================================================
; iocmd.asm - shell commands for Part 3 (menu option 2)
; Included by kernel.asm after memcmd.asm (uses its PRINT macro).
;
; io_command: run cmd_buf if it is an I/O command.
;   out: CF=0 handled | CF=1 not an I/O command. Preserves registers.
; =====================================================================
%macro IOCMD 2                      ; literal, handler label
    mov esi, cmd_buf
    mov edi, %%lit
    call str_eq_ci
    test al, al
    jnz %2
    jmp %%next
%%lit: db %1, 0
%%next:
%endmacro

io_command:
    pushad
    IOCMD "2", io_help
    IOCMD "iohelp", io_help
    IOCMD "ticks", io_ticks
    IOCMD "iomap", io_iomap
    IOCMD "irqstat", io_irqstat
    IOCMD "int3", io_int3
    IOCMD "div0", io_div0
    popad
    stc
    ret

io_done:
    popad
    clc
    ret

io_help:
    PRINT {"=== Interrupt Driven IO Management ===", 10}
    PRINT {"TICKS     timer ticks and uptime (PIT, IRQ0)", 10}
    PRINT {"IOMAP     device I/O map table", 10}
    PRINT {"IRQSTAT   IRQ counters, spurious IRQs, key buffer overflows", 10}
    PRINT {"INT3      trigger a breakpoint exception (system continues)", 10}
    PRINT {"DIV0      trigger a divide error (system HALTS, reboot to recover)", 10}
    jmp io_done

io_ticks:
    PRINT "ticks: "
    mov eax, [tick_count]
    xor edx, edx
    mov ecx, TIMER_HZ
    div ecx                         ; EAX = seconds, EDX = leftover ticks
    push eax
    imul eax, edx, 100
    xor edx, edx
    div ecx                         ; EAX = hundredths of a second
    mov ebx, eax
    mov eax, [tick_count]
    call kputdec
    PRINT "   uptime: "
    pop eax
    call kputdec
    mov al, '.'
    call kputc
    mov eax, ebx
    xor edx, edx
    mov ecx, 10
    div ecx                         ; AL = tens, DL = ones
    add al, '0'
    call kputc
    mov al, dl
    add al, '0'
    call kputc
    PRINT {" s", 10}
    jmp io_done

io_iomap:
    call io_map_dump
    jmp io_done

io_irqstat:
    PRINT "IRQ0 timer fired:    "
    mov eax, [irq_counts + 0*4]
    call kputdec
    call newline
    PRINT "IRQ1 keyboard fired: "
    mov eax, [irq_counts + 1*4]
    call kputdec
    call newline
    PRINT "spurious IRQs:       "
    mov eax, [spurious_count]
    call kputdec
    call newline
    PRINT "unhandled vectors:   "
    mov eax, [unhandled_count]
    call kputdec
    call newline
    PRINT "key buffer overflow: "
    mov eax, [kbd_overflow]
    call kputdec
    call newline
    jmp io_done

io_int3:
    int3                            ; exception_handler reports it and returns
    jmp io_done

io_div0:
    PRINT {"Triggering divide error...", 10}
    xor ebx, ebx
    mov eax, 1
    div ebx                         ; -> #DE, handler halts the machine
    jmp io_done
