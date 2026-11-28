; ============================================================
; msgpassing.asm - BuddyOS IPC: message passing (NASM, 32-bit)
;
; SELF-CONTAINED: needs no other BuddyOS file (except the optional
; ipc_dump uses the kernel print routines). All names start with
; ipc_ / msg_ / IPC_ so they will not clash with other modules.
;
; Calling convention (C "cdecl"): push args right-to-left, result in
; EAX, CALLER cleans the stack (add esp, N). EBX/ESI/EDI/EBP preserved.
; EAX, ECX, EDX are clobbered -> an ISR must pushad/popad around calls.
;
; INTERRUPT SAFE: every queue/state change runs with interrupts off
; (pushfd/cli ... popfd), so a keyboard or timer ISR can never see a
; half-updated mailbox. Flags (IF) are restored, never forced on.
;
;   ipc_init()                                -> 0
;   ipc_register(name_ptr)                    -> pid | IPC_ERR_NOSLOT
;   ipc_unregister(pid)                       -> 0   | IPC_ERR_BADPID
;   msg_send(from, to, type, data_ptr, len)   -> 0   | error
;        from = IPC_FROM_ISR (255) lets an interrupt handler post a
;        message without being a registered process.
;   msg_recv(pid, msg_ptr)         non-blocking -> 0 | error
;   msg_recv_wait(pid, msg_ptr)    blocking     -> 0 | error
;   msg_pending(pid)                          -> count | IPC_ERR_BADPID
;   ipc_set_yield(fn_ptr)   scheduler hook (0 = none)
;
; Memory: the mailbox table lives at IPC_TABLE (3 KB). The default
; 0x20000 must NOT overlap your buddy pool / stacks / kernel. To move
; it, put   %define IPC_TABLE 0x....   before including this file
; (e.g. in constants.inc).
; ============================================================

%ifndef IPC_TABLE
%define IPC_TABLE 0x20000
%endif

IPC_MAX_PROCS    equ 8
IPC_MAILBOX_LEN  equ 8
IPC_MSG_DATA     equ 32
IPC_NAME_LEN     equ 16
IPC_FROM_ISR     equ 255

; return codes
IPC_OK           equ 0
IPC_ERR_BADPID   equ -1
IPC_ERR_FULL     equ -2
IPC_ERR_EMPTY    equ -3
IPC_ERR_NOSLOT   equ -4
IPC_ERR_SIZE     equ -5

; process states
IPC_PROC_FREE    equ 0
IPC_PROC_READY   equ 1
IPC_PROC_BLOCKED equ 2

; message layout (44 bytes) - use these offsets to read a received msg_t
IPC_M_SENDER     equ 0
IPC_M_TYPE       equ 4
IPC_M_LEN        equ 8
IPC_M_DATA       equ 12
IPC_MSG_SIZE     equ 12 + IPC_MSG_DATA

; process entry layout (384 bytes each)
IPC_P_STATE      equ 0
IPC_P_HEAD       equ 4
IPC_P_TAIL       equ 8
IPC_P_COUNT      equ 12
IPC_P_NAME       equ 16
IPC_P_BOX        equ 32
IPC_P_SIZE       equ 32 + IPC_MAILBOX_LEN * IPC_MSG_SIZE

ipc_yield_hook   dd 0

; ---- internal: EAX = pid -> EAX = proc pointer, or 0 if invalid/free
_ipc_get:
    cmp eax, IPC_MAX_PROCS
    jae .bad                         ; unsigned: also rejects negatives
    imul eax, IPC_P_SIZE
    add eax, IPC_TABLE
    cmp dword [eax + IPC_P_STATE], IPC_PROC_FREE
    je .bad
    ret
.bad:
    xor eax, eax
    ret

; ---- int ipc_init(void)
ipc_init:
    push edi
    pushfd
    cli
    cld
    mov edi, IPC_TABLE
    mov ecx, (IPC_P_SIZE * IPC_MAX_PROCS) / 4
    xor eax, eax
    rep stosd
    mov dword [ipc_yield_hook], 0
    popfd
    pop edi
    xor eax, eax
    ret

; ---- int ipc_register(const char *name)
ipc_register:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi
    xor ecx, ecx
.scan:
    cmp ecx, IPC_MAX_PROCS
    jae .noslot
    mov eax, ecx
    imul eax, IPC_P_SIZE
    add eax, IPC_TABLE
    cmp dword [eax + IPC_P_STATE], IPC_PROC_FREE
    je .found
    inc ecx
    jmp .scan
.found:
    mov dword [eax + IPC_P_HEAD], 0
    mov dword [eax + IPC_P_TAIL], 0
    mov dword [eax + IPC_P_COUNT], 0
    mov esi, [ebp + 8]               ; name
    lea edi, [eax + IPC_P_NAME]
    mov edx, IPC_NAME_LEN - 1
.copy:
    mov bl, [esi]
    test bl, bl
    jz .term
    test edx, edx
    jz .term
    mov [edi], bl
    inc esi
    inc edi
    dec edx
    jmp .copy
.term:
    mov byte [edi], 0
    mov dword [eax + IPC_P_STATE], IPC_PROC_READY   ; publish last
    mov eax, ecx                     ; return pid
    jmp .out
.noslot:
    mov eax, IPC_ERR_NOSLOT
.out:
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

; ---- int ipc_unregister(int pid)
ipc_unregister:
    mov eax, [esp + 4]
    pushfd
    cli
    call _ipc_get
    test eax, eax
    jz .bad
    mov dword [eax + IPC_P_STATE], IPC_PROC_FREE
    mov dword [eax + IPC_P_HEAD], 0
    mov dword [eax + IPC_P_TAIL], 0
    mov dword [eax + IPC_P_COUNT], 0
    xor eax, eax
    popfd
    ret
.bad:
    mov eax, IPC_ERR_BADPID
    popfd
    ret

; ---- int msg_send(int from, int to, int type, const void *data, uint len)
msg_send:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi
    pushfd
    cli                              ; ---- critical section begins
    ; [ebp+8]=from [ebp+12]=to [ebp+16]=type [ebp+20]=data [ebp+24]=len
    mov eax, [ebp + 12]
    call _ipc_get
    test eax, eax
    jz .badpid
    mov ebx, eax                     ; ebx = destination proc
    cmp dword [ebp + 8], IPC_FROM_ISR
    je .sender_ok                    ; interrupt handlers need no mailbox
    mov eax, [ebp + 8]
    call _ipc_get
    test eax, eax
    jz .badpid
.sender_ok:
    mov ecx, [ebp + 24]
    cmp ecx, IPC_MSG_DATA
    ja .size
    cmp dword [ebx + IPC_P_COUNT], IPC_MAILBOX_LEN
    jae .full

    mov eax, [ebx + IPC_P_TAIL]
    imul eax, IPC_MSG_SIZE
    lea edi, [ebx + IPC_P_BOX + eax] ; edi = slot to write
    mov eax, [ebp + 8]
    mov [edi + IPC_M_SENDER], eax
    mov eax, [ebp + 16]
    mov [edi + IPC_M_TYPE], eax
    mov [edi + IPC_M_LEN], ecx
    mov esi, [ebp + 20]
    add edi, IPC_M_DATA
    cld
    rep movsb                        ; copy len bytes (ecx = len)

    mov eax, [ebx + IPC_P_TAIL]      ; tail = (tail + 1) % LEN
    inc eax
    cmp eax, IPC_MAILBOX_LEN
    jb .tail_ok
    xor eax, eax
.tail_ok:
    mov [ebx + IPC_P_TAIL], eax
    inc dword [ebx + IPC_P_COUNT]
    cmp dword [ebx + IPC_P_STATE], IPC_PROC_BLOCKED
    jne .sent
    mov dword [ebx + IPC_P_STATE], IPC_PROC_READY    ; wake the receiver
.sent:
    xor eax, eax
    jmp .out
.badpid:
    mov eax, IPC_ERR_BADPID
    jmp .out
.full:
    mov eax, IPC_ERR_FULL
    jmp .out
.size:
    mov eax, IPC_ERR_SIZE
.out:
    popfd                            ; ---- critical section ends
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

; ---- internal: EAX = pid, EDX = out ptr -> EAX = result.
;      NO interrupt handling: callers must already have done cli.
_msg_recv_core:
    push ebx
    push esi
    push edi
    call _ipc_get
    test eax, eax
    jz .badpid
    mov ebx, eax
    cmp dword [ebx + IPC_P_COUNT], 0
    je .empty
    mov eax, [ebx + IPC_P_HEAD]
    imul eax, IPC_MSG_SIZE
    lea esi, [ebx + IPC_P_BOX + eax]
    mov edi, edx
    mov ecx, IPC_MSG_SIZE / 4
    cld
    rep movsd
    mov eax, [ebx + IPC_P_HEAD]      ; head = (head + 1) % LEN
    inc eax
    cmp eax, IPC_MAILBOX_LEN
    jb .head_ok
    xor eax, eax
.head_ok:
    mov [ebx + IPC_P_HEAD], eax
    dec dword [ebx + IPC_P_COUNT]
    xor eax, eax
    jmp .out
.badpid:
    mov eax, IPC_ERR_BADPID
    jmp .out
.empty:
    mov eax, IPC_ERR_EMPTY
.out:
    pop edi
    pop esi
    pop ebx
    ret

; ---- int msg_recv(int pid, msg_t *out)        (non-blocking)
msg_recv:
    mov eax, [esp + 4]
    mov edx, [esp + 8]
    pushfd
    cli
    call _msg_recv_core
    popfd
    ret

; ---- int msg_recv_wait(int pid, msg_t *out)   (blocking)
; Checks the mailbox and marks the task BLOCKED in ONE critical section,
; so a message that arrives in between can never be missed (no lost
; wake-up). Then calls the yield hook and retries. With no hook it
; returns IPC_ERR_EMPTY instead of hanging forever.
msg_recv_wait:
    push ebp
    mov ebp, esp
    push ebx
    ; [ebp+8]=pid [ebp+12]=out
.try:
    mov eax, [ebp + 8]
    mov edx, [ebp + 12]
    pushfd
    cli
    call _msg_recv_core
    cmp eax, IPC_ERR_EMPTY
    jne .finish
    mov eax, [ebp + 8]
    call _ipc_get
    test eax, eax
    jz .bad
    mov dword [eax + IPC_P_STATE], IPC_PROC_BLOCKED
    popfd                            ; interrupts back; wake-ups now visible
    mov ebx, [ipc_yield_hook]
    test ebx, ebx
    jz .nohook
    call ebx                         ; run other tasks
    jmp .try
.nohook:
    mov eax, [ebp + 8]
    call _ipc_get
    test eax, eax
    jz .empty
    mov dword [eax + IPC_P_STATE], IPC_PROC_READY
.empty:
    mov eax, IPC_ERR_EMPTY
    jmp .out
.bad:
    popfd
    mov eax, IPC_ERR_BADPID
    jmp .out
.finish:
    popfd
    test eax, eax
    jnz .out
    push eax                         ; got a message: mark READY
    mov eax, [ebp + 8]
    call _ipc_get
    test eax, eax
    jz .skip
    mov dword [eax + IPC_P_STATE], IPC_PROC_READY
.skip:
    pop eax
.out:
    pop ebx
    pop ebp
    ret

; ---- int msg_pending(int pid)
msg_pending:
    mov eax, [esp + 4]
    call _ipc_get
    test eax, eax
    jz .bad
    mov eax, [eax + IPC_P_COUNT]
    ret
.bad:
    mov eax, IPC_ERR_BADPID
    ret

; ---- void ipc_set_yield(void (*fn)(void))
ipc_set_yield:
    mov eax, [esp + 4]
    mov [ipc_yield_hook], eax
    ret

; ---- void ipc_dump(void) - mailbox status for demos/commands.
; Uses the kernel's print_string (ESI), print_dec (EAX) and newline.
ipc_dump:
    push ebx
    push esi
    push ecx
    xor ecx, ecx
.loop:
    cmp ecx, IPC_MAX_PROCS
    jae .done
    mov eax, ecx
    call _ipc_get
    test eax, eax
    jz .next
    mov ebx, eax
    mov esi, _ipc_s_pid
    call print_string
    mov eax, ecx
    call print_dec
    mov esi, _ipc_s_name
    call print_string
    lea esi, [ebx + IPC_P_NAME]
    call print_string
    mov esi, _ipc_s_state
    call print_string
    mov esi, _ipc_s_ready
    cmp dword [ebx + IPC_P_STATE], IPC_PROC_BLOCKED
    jne .p
    mov esi, _ipc_s_blocked
.p: call print_string
    mov esi, _ipc_s_msgs
    call print_string
    mov eax, [ebx + IPC_P_COUNT]
    call print_dec
    call newline
.next:
    inc ecx
    jmp .loop
.done:
    pop ecx
    pop esi
    pop ebx
    ret

_ipc_s_pid     db "  pid=", 0
_ipc_s_name    db " name=", 0
_ipc_s_state   db " state=", 0
_ipc_s_msgs    db " msgs=", 0
_ipc_s_ready   db "READY", 0
_ipc_s_blocked db "BLOCKED", 0


; ############################################################
; PART 2 - SELF-TEST  (run with the shell command: ipc test)
; ############################################################
; ============================================================
; msgpassing_test.asm - boot-time self-test for msgpassing.asm
; Call  ipc_selftest  once from your kernel. It prints PASS/FAIL.
;
; Wrappers around the kernel's print routines. They PRESERVE EAX,
; because the test reads msg_send/msg_recv results after printing
; (the kernel's own newline/putchar clobber EAX).
; ============================================================
t_str:   jmp print_string
t_dec:   jmp print_dec
t_nl:
    push eax
    call newline
    pop eax
    ret
t_sdec:                              ; signed decimal, preserves EAX
    test eax, eax
    jns print_dec
    push eax
    mov al, '-'
    call putchar
    pop eax
    neg eax
    call print_dec
    neg eax
    ret

ts_pid_a   dd 0
ts_pid_b   dd 0
ts_fails   dd 0
ts_saved_hook dd 0

ts_na      db "shell", 0
ts_nb      db "worker", 0
ts_ping    db "ping", 0
ts_pong    db "pong", 0
ts_wake    db "wake", 0
ts_key     db "k", 0
ts_big     db "0123456789012345678901234567890123456789", 0

ts_hdr     db "[ipc] --- message passing self-test ---", 0
ts_s1      db "[ipc] shell -> worker: ping", 0
ts_gw      db "[ipc] worker received: ", 0
ts_gs      db "[ipc] shell received:  ", 0
ts_from    db " (from pid ", 0
ts_close   db ")", 0
ts_bad     db "[ipc] send to unregistered pid 5 -> err ", 0
ts_size    db "[ipc] send 40-byte payload       -> err ", 0
ts_full    db "[ipc] 9th msg to full mailbox    -> err ", 0
ts_empty   db "[ipc] recv from empty mailbox    -> err ", 0
ts_isr     db "[ipc] ISR-style post (from 255)  -> got: ", 0
ts_blk     db "[ipc] blocking recv woke with:   ", 0
ts_pass    db "[ipc] RESULT: ALL CHECKS PASSED", 0
ts_fail    db "[ipc] RESULT: SOME CHECKS FAILED", 0

; ECX = expected, EAX = actual
ts_expect:
    cmp eax, ecx
    je .ok
    inc dword [ts_fails]
.ok:
    ret

; stand-in for a scheduler: acts as "the other process" and sends
ts_yield:
    push dword 5
    push ts_wake
    push dword 7
    push dword [ts_pid_b]
    push dword [ts_pid_a]
    call msg_send
    add esp, 20
    ret

; helper: msg_send(from, to, type, data, len)  (args already in regs)
; macro keeps the test readable
%macro SEND 5
    push dword %5
    push %4
    push dword %3
    push dword %2
    push dword %1
    call msg_send
    add esp, 20
%endmacro

ipc_selftest:
    push ebp
    mov ebp, esp
    sub esp, IPC_MSG_SIZE            ; local message buffer at [ebp-44]
    pushad
    mov esi, ts_hdr
    call t_str
    call t_nl

    mov eax, [ipc_yield_hook]        ; remember the real scheduler hook
    mov [ts_saved_hook], eax
    call ipc_init
    push ts_na
    call ipc_register
    add esp, 4
    mov [ts_pid_a], eax
    push ts_nb
    call ipc_register
    add esp, 4
    mov [ts_pid_b], eax

    ; 1) shell -> worker
    mov esi, ts_s1
    call t_str
    call t_nl
    SEND [ts_pid_a], [ts_pid_b], 1, ts_ping, 5
    xor ecx, ecx
    call ts_expect
    call ipc_dump
    lea eax, [ebp - IPC_MSG_SIZE]
    push eax
    push dword [ts_pid_b]
    call msg_recv
    add esp, 8
    xor ecx, ecx
    call ts_expect
    mov esi, ts_gw
    call t_str
    lea esi, [ebp - IPC_MSG_SIZE + IPC_M_DATA]
    call t_str
    mov esi, ts_from
    call t_str
    mov eax, [ebp - IPC_MSG_SIZE + IPC_M_SENDER]
    call t_dec
    mov esi, ts_close
    call t_str
    call t_nl

    ; 2) worker -> shell
    SEND [ts_pid_b], [ts_pid_a], 2, ts_pong, 5
    lea eax, [ebp - IPC_MSG_SIZE]
    push eax
    push dword [ts_pid_a]
    call msg_recv
    add esp, 8
    mov esi, ts_gs
    call t_str
    lea esi, [ebp - IPC_MSG_SIZE + IPC_M_DATA]
    call t_str
    mov esi, ts_from
    call t_str
    mov eax, [ebp - IPC_MSG_SIZE + IPC_M_SENDER]
    call t_dec
    mov esi, ts_close
    call t_str
    call t_nl

    ; 3) bad pid
    SEND [ts_pid_a], 5, 1, ts_ping, 0
    mov esi, ts_bad
    call t_str
    call t_sdec
    call t_nl
    mov ecx, IPC_ERR_BADPID
    call ts_expect

    ; 4) payload too large
    SEND [ts_pid_a], [ts_pid_b], 1, ts_big, 40
    mov esi, ts_size
    call t_str
    call t_sdec
    call t_nl
    mov ecx, IPC_ERR_SIZE
    call ts_expect

    ; 5) full mailbox
    mov ebx, IPC_MAILBOX_LEN
.fill:
    SEND [ts_pid_a], [ts_pid_b], 1, ts_ping, 0
    dec ebx
    jnz .fill
    SEND [ts_pid_a], [ts_pid_b], 1, ts_ping, 0
    mov esi, ts_full
    call t_str
    call t_sdec
    call t_nl
    mov ecx, IPC_ERR_FULL
    call ts_expect
    mov ebx, IPC_MAILBOX_LEN
.drain:
    lea eax, [ebp - IPC_MSG_SIZE]
    push eax
    push dword [ts_pid_b]
    call msg_recv
    add esp, 8
    dec ebx
    jnz .drain

    ; 6) empty mailbox
    lea eax, [ebp - IPC_MSG_SIZE]
    push eax
    push dword [ts_pid_b]
    call msg_recv
    add esp, 8
    mov esi, ts_empty
    call t_str
    call t_sdec
    call t_nl
    mov ecx, IPC_ERR_EMPTY
    call ts_expect

    ; 7) ISR-style post: from = IPC_FROM_ISR, no sender process needed
    SEND IPC_FROM_ISR, [ts_pid_a], 9, ts_key, 2
    lea eax, [ebp - IPC_MSG_SIZE]
    push eax
    push dword [ts_pid_a]
    call msg_recv
    add esp, 8
    xor ecx, ecx
    call ts_expect
    mov esi, ts_isr
    call t_str
    lea esi, [ebp - IPC_MSG_SIZE + IPC_M_DATA]
    call t_str
    mov esi, ts_from
    call t_str
    mov eax, [ebp - IPC_MSG_SIZE + IPC_M_SENDER]
    call t_dec
    mov esi, ts_close
    call t_str
    call t_nl
    cmp dword [ebp - IPC_MSG_SIZE + IPC_M_SENDER], IPC_FROM_ISR
    je .isr_ok
    inc dword [ts_fails]
.isr_ok:

    ; 8) blocking receive using the yield hook
    push ts_yield
    call ipc_set_yield
    add esp, 4
    lea eax, [ebp - IPC_MSG_SIZE]
    push eax
    push dword [ts_pid_b]
    call msg_recv_wait
    add esp, 8
    xor ecx, ecx
    call ts_expect
    mov esi, ts_blk
    call t_str
    lea esi, [ebp - IPC_MSG_SIZE + IPC_M_DATA]
    call t_str
    call t_nl
    push dword [ts_saved_hook]       ; put the real hook back
    call ipc_set_yield
    add esp, 4

    cmp dword [ts_fails], 0
    jne .failed
    mov esi, ts_pass
    jmp .verdict
.failed:
    mov esi, ts_fail
.verdict:
    call t_str
    call t_nl
    popad
    mov esp, ebp
    pop ebp
    ret


; ############################################################
; PART 3 - SHELL COMMANDS  (menu option 3)
; ############################################################
; =====================================================================
; ipccmd.asm - shell commands for IPC message passing (menu option 3)
;
; ipc_command : same contract as mem_command / io_command
;               in : cmd_buf (zero-terminated)   out: CF=0 handled, CF=1 not mine
; ipc_boot    : (re)initialise IPC and register pid 0 = "shell"
; Needs the kernel's print_string / print_dec / newline / cmd_buf.
; Process ids are single digits 0-7 (IPC_MAX_PROCS = 8).
; =====================================================================

ic_from     dd 0
ic_to       dd 0

ic_k_ipc    db "ipc", 0
ic_k_status db "status", 0
ic_k_new    db "new", 0
ic_k_send   db "send", 0
ic_k_recv   db "recv", 0
ic_k_free   db "free", 0
ic_k_test   db "test", 0
ic_s_shell  db "shell", 0

ic_help     db "=== IPC MESSAGE PASSING ===", 10
            db "ipc status                  show processes and mailbox counts", 10
            db "ipc new <name>              create a process (gets a mailbox)", 10
            db "ipc send <from> <to> <text> send a message (pids 0-7)", 10
            db "ipc recv <pid>              take the next message from a mailbox", 10
            db "ipc free <pid>              remove a process", 10
            db "ipc test                    run the IPC self-test", 10, 0
ic_m_created db "Process created, pid ", 0
ic_m_noslot  db "Process table full (max 8)", 10, 0
ic_m_freed   db "Process removed", 10, 0
ic_m_sent    db "Message sent", 10, 0
ic_m_full    db "Failed: destination mailbox is full (8 messages)", 10, 0
ic_m_badpid  db "Failed: pid not registered (see 'ipc status')", 10, 0
ic_m_size    db "Failed: message too long (max 31 characters)", 10, 0
ic_m_empty   db "Mailbox is empty", 10, 0
ic_m_from    db "Message from pid ", 0
ic_m_colon   db ": ", 0
ic_m_reset   db "(IPC reset: only pid 0 'shell' remains)", 10, 0

; ---- void ipc_boot(void)
ipc_boot:
    call ipc_init
    push ic_s_shell
    call ipc_register                ; becomes pid 0
    add esp, 4
    ret

; ---- ic_word: ESI -> input, EDI -> lowercase keyword.
;      match (whole word): AL=1, ESI -> past the word and spaces
;      no match:           AL=0, ESI unchanged
ic_word:
    push ebx
    push edx
    mov edx, esi
.cmp:
    mov al, [edi]
    test al, al
    jz .end_kw
    mov bl, [esi]
    cmp bl, 'A'
    jb .cased
    cmp bl, 'Z'
    ja .cased
    add bl, 32
.cased:
    cmp al, bl
    jne .no
    inc esi
    inc edi
    jmp .cmp
.end_kw:
    mov bl, [esi]
    test bl, bl
    jz .yes
    cmp bl, ' '
    jne .no
.yes:
    cmp byte [esi], ' '
    jne .matched
    inc esi
    jmp .yes
.matched:
    mov al, 1
    pop edx
    pop ebx
    ret
.no:
    mov esi, edx
    xor al, al
    pop edx
    pop ebx
    ret

; ---- ic_digit: ESI -> one digit 0-7 followed by space or end.
;      ok: CF=0, EAX = value, ESI advanced past digit + spaces
;      bad: CF=1
ic_digit:
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, IPC_MAX_PROCS - 1
    ja .bad
    mov dl, [esi + 1]
    test dl, dl
    jz .ok
    cmp dl, ' '
    jne .bad
.ok:
    inc esi
.skip:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp .skip
.done:
    clc
    ret
.bad:
    stc
    ret

; ---- ipc_command
ipc_command:
    pushad
    mov esi, cmd_buf
    cmp byte [esi], '3'              ; menu option "3"
    jne .try_ipc
    cmp byte [esi + 1], 0
    je .help
.try_ipc:
    mov edi, ic_k_ipc
    call ic_word
    test al, al
    jz .not_mine
    cmp byte [esi], 0                ; bare "ipc"
    je .help
    mov edi, ic_k_status
    call ic_word
    test al, al
    jnz .status
    mov edi, ic_k_new
    call ic_word
    test al, al
    jnz .new
    mov edi, ic_k_send
    call ic_word
    test al, al
    jnz .send
    mov edi, ic_k_recv
    call ic_word
    test al, al
    jnz .recv
    mov edi, ic_k_free
    call ic_word
    test al, al
    jnz .free
    mov edi, ic_k_test
    call ic_word
    test al, al
    jnz .test
.help:
    mov esi, ic_help
    call print_string
    jmp .handled

.status:
    call ipc_dump
    jmp .handled

.new:
    cmp byte [esi], 0
    je .help
    push esi
    call ipc_register
    add esp, 4
    test eax, eax
    js .noslot
    push eax
    mov esi, ic_m_created
    call print_string
    pop eax
    call print_dec
    call newline
    jmp .handled
.noslot:
    mov esi, ic_m_noslot
    call print_string
    jmp .handled

.send:
    call ic_digit
    jc .help
    mov [ic_from], eax
    call ic_digit
    jc .help
    mov [ic_to], eax
    cmp byte [esi], 0
    je .help
    xor ecx, ecx                     ; ecx = strlen(text) + 1 (keeps the 0)
.len:
    cmp byte [esi + ecx], 0
    je .len_done
    inc ecx
    jmp .len
.len_done:
    inc ecx
    push ecx                         ; len
    push esi                         ; data
    push dword 1                     ; type
    push dword [ic_to]
    push dword [ic_from]
    call msg_send
    add esp, 20
    mov esi, ic_m_sent
    test eax, eax
    jz .say
    mov esi, ic_m_full
    cmp eax, IPC_ERR_FULL
    je .say
    mov esi, ic_m_size
    cmp eax, IPC_ERR_SIZE
    je .say
    mov esi, ic_m_badpid
.say:
    call print_string
    jmp .handled

.recv:
    call ic_digit
    jc .help
    mov ebx, eax                     ; pid
    sub esp, IPC_MSG_SIZE            ; message buffer on the stack
    mov edx, esp
    push edx
    push ebx
    call msg_recv
    add esp, 8
    test eax, eax
    jnz .recv_fail
    mov byte [esp + IPC_M_DATA + IPC_MSG_DATA - 1], 0   ; always terminated
    mov esi, ic_m_from
    call print_string
    mov eax, [esp + IPC_M_SENDER]
    call print_dec
    mov esi, ic_m_colon
    call print_string
    lea esi, [esp + IPC_M_DATA]
    call print_string
    call newline
    add esp, IPC_MSG_SIZE
    jmp .handled
.recv_fail:
    add esp, IPC_MSG_SIZE
    mov esi, ic_m_empty
    cmp eax, IPC_ERR_EMPTY
    je .say
    mov esi, ic_m_badpid
    jmp .say

.free:
    call ic_digit
    jc .help
    push eax
    call ipc_unregister
    add esp, 4
    mov esi, ic_m_freed
    test eax, eax
    jz .say
    mov esi, ic_m_badpid
    jmp .say

.test:
    call ipc_selftest
    call ipc_boot
    push dword [ts_saved_hook]       ; ipc_boot cleared the hook: restore it
    call ipc_set_yield
    add esp, 4
    mov esi, ic_m_reset
    call print_string
    jmp .handled

.handled:
    popad
    clc
    ret
.not_mine:
    popad
    stc
    ret