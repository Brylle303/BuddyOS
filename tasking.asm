; =====================================================================
; tasking.asm - BuddyOS cooperative tasking + producer/consumer demo
; (NASM, 32-bit). Needs msgpassing.asm included BEFORE this file.
;
; IDEA: a task is (1) its own stack and (2) a saved ESP. Switching
; tasks = save my ESP, load the other's ESP, 'ret'. The ret resumes the
; other task exactly where it stopped.
;
;   tasks_init()                 call once at boot, AFTER ipc_boot
;   task_create(entry, name)     -> task id | -1      (id == IPC pid)
;   task_yield()                 give the CPU to the next ready task
;   tasks_alive()                -> number of live tasks (incl. shell)
;   task_list()                  print the task table
;   task_command                 shell: task / task demo / task list
;
; Scheduling is COOPERATIVE round-robin: a task runs until it calls
; task_yield (directly, or inside msg_recv_wait when its mailbox is
; empty). The shell (kernel_idle loop) is task 0.
; A task is "blocked" when IPC says so: the scheduler skips any task
; whose IPC state is IPC_PROC_BLOCKED, and msg_send wakes it.
; Same convention as msgpassing.asm: cdecl, EAX result, caller cleans.
; =====================================================================

%ifndef TASK_STACK_BASE
%define TASK_STACK_BASE 0x30000      ; task N's stack top = BASE + (N+1)*4 KB
%endif
TASK_MAX        equ IPC_MAX_PROCS
TASK_STACK_SIZE equ 0x1000

TASK_FREE       equ 0
TASK_READY      equ 1
TCB_STATE       equ 0
TCB_ESP         equ 4
TCB_SIZE        equ 8

task_current    dd 0
task_tcbs       times TASK_MAX * TCB_SIZE db 0

; ---- void tasks_init(void)   current code becomes task 0 ("shell")
tasks_init:
    push edi
    cld
    mov edi, task_tcbs
    mov ecx, (TASK_MAX * TCB_SIZE) / 4
    xor eax, eax
    rep stosd
    mov dword [task_tcbs + TCB_STATE], TASK_READY
    mov dword [task_current], 0
    push task_yield
    call ipc_set_yield               ; blocking receive now yields to others
    add esp, 4
    pop edi
    ret

; ---- int task_create(void (*entry)(void), const char *name)
task_create:
    push ebp
    mov ebp, esp
    push ebx
    push edi
    ; [ebp+8]=entry  [ebp+12]=name
    push dword [ebp + 12]
    call ipc_register                ; mailbox first: its pid IS the task id
    add esp, 4
    test eax, eax
    js .full
    mov ebx, eax                     ; ebx = task id
    ; fake stack frame, as if the task had just been switched out:
    ;   top-4 : task_exit    (entry's 'ret' lands here)
    ;   top-8 : entry        (task_start's 'ret' lands here)
    ;   top-12: task_start   (switch_to's 'ret' lands here: does STI)
    ;   top-16..28: ebp, edi, esi, ebx  (switch_to pops these)
    lea edi, [ebx + 1]
    shl edi, 12                      ; * TASK_STACK_SIZE
    add edi, TASK_STACK_BASE         ; edi = top of this task's stack
    mov dword [edi - 4], task_exit
    mov eax, [ebp + 8]
    mov dword [edi - 8], eax
    mov dword [edi - 12], task_start
    mov dword [edi - 16], 0
    mov dword [edi - 20], 0
    mov dword [edi - 24], 0
    mov dword [edi - 28], 0
    sub edi, 28
    mov eax, ebx
    imul eax, TCB_SIZE
    mov [task_tcbs + eax + TCB_ESP], edi
    mov dword [task_tcbs + eax + TCB_STATE], TASK_READY
    mov eax, ebx
    jmp .out
.full:
    mov eax, -1
.out:
    pop edi
    pop ebx
    pop ebp
    ret

; first thing a brand-new task runs: switching happened with IF=0
task_start:
    sti
    ret                              ; -> entry

; ---- void task_switch_to(tcb *old, tcb *new)      THE context switch
task_switch_to:
    mov eax, [esp + 4]
    mov edx, [esp + 8]
    push ebp                         ; save callee-saved registers
    push edi
    push esi
    push ebx
    mov [eax + TCB_ESP], esp         ; remember where the old task stopped
    mov esp, [edx + TCB_ESP]         ; <<< now on the NEW task's stack
    pop ebx
    pop esi
    pop edi
    pop ebp
    ret                              ; resumes the new task

; ---- void task_yield(void)   round-robin; skips FREE and IPC-BLOCKED tasks
task_yield:
    push ebx
    mov ebx, [task_current]
    mov ecx, ebx
.search:
    inc ecx
    cmp ecx, TASK_MAX
    jb .check
    xor ecx, ecx
.check:
    cmp ecx, ebx
    je .none                         ; full circle: nobody else wants the CPU
    mov eax, ecx
    imul eax, TCB_SIZE
    cmp dword [task_tcbs + eax + TCB_STATE], TASK_READY
    jne .search
    mov edx, ecx
    imul edx, IPC_P_SIZE
    cmp dword [IPC_TABLE + edx + IPC_P_STATE], IPC_PROC_BLOCKED
    je .search
    mov [task_current], ecx          ; found: switch ebx -> ecx
    imul ebx, TCB_SIZE
    add ebx, task_tcbs               ; old tcb
    imul ecx, TCB_SIZE
    add ecx, task_tcbs               ; new tcb
    pushfd                           ; flags are per-task
    cli                              ; no interrupt mid-switch
    push ecx
    push ebx
    call task_switch_to
    add esp, 8
    popfd                            ; (runs when we are switched back in)
.none:
    pop ebx
    ret

; ---- runs when a task's entry function returns
task_exit:
    cli
    mov eax, [task_current]
    imul eax, TCB_SIZE
    mov dword [task_tcbs + eax + TCB_STATE], TASK_FREE
    push dword [task_current]
    call ipc_unregister
    add esp, 4
    sti
.forever:
    call task_yield
    jmp .forever

; ---- int tasks_alive(void)
tasks_alive:
    xor eax, eax
    xor ecx, ecx
.count:
    cmp ecx, TASK_MAX
    jae .done
    mov edx, ecx
    imul edx, TCB_SIZE
    cmp dword [task_tcbs + edx + TCB_STATE], TASK_READY
    jne .next
    inc eax
.next:
    inc ecx
    jmp .count
.done:
    ret

; ---- void task_list(void)
task_list:
    pushad
    xor ebx, ebx
.loop:
    cmp ebx, TASK_MAX
    jae .done
    mov eax, ebx
    imul eax, TCB_SIZE
    cmp dword [task_tcbs + eax + TCB_STATE], TASK_READY
    jne .next
    mov esi, tk_s_id
    call print_string
    mov eax, ebx
    call print_dec
    mov esi, tk_s_name
    call print_string
    mov eax, ebx
    imul eax, IPC_P_SIZE
    lea esi, [IPC_TABLE + eax + IPC_P_NAME]
    call print_string
    mov esi, tk_s_state
    call print_string
    mov esi, tk_s_ready
    cmp ebx, [task_current]
    jne .not_cur
    mov esi, tk_s_running
    jmp .show
.not_cur:
    mov eax, ebx
    imul eax, IPC_P_SIZE
    cmp dword [IPC_TABLE + eax + IPC_P_STATE], IPC_PROC_BLOCKED
    jne .show
    mov esi, tk_s_blocked
.show:
    call print_string
    call newline
.next:
    inc ebx
    jmp .loop
.done:
    popad
    ret

; =====================================================================
; Demo: producer sends 5 messages, consumer blocks waiting for them.
; =====================================================================
tk_prod_pid  dd 0
tk_cons_pid  dd 0

tk_n_cons    db "consumer", 0
tk_n_prod    db "producer", 0
tk_msgs      db "msg 1", 0, 0, 0
             db "msg 2", 0, 0, 0
             db "msg 3", 0, 0, 0
             db "msg 4", 0, 0, 0
             db "msg 5", 0, 0, 0

tk_s_id      db "  id=", 0
tk_s_name    db " name=", 0
tk_s_state   db " state=", 0
tk_s_ready   db "READY", 0
tk_s_running db "RUNNING", 0
tk_s_blocked db "BLOCKED", 0

tk_c_wait    db "[consumer] mailbox empty -> blocking...", 10, 0
tk_c_got     db "[consumer] woke up, got: ", 0
tk_c_from    db "  (from pid ", 0
tk_c_close   db ")", 10, 0
tk_p_table   db "[producer] task table right now:", 10, 0
tk_p_sent    db "[producer] sent: ", 0

tk_consumer:
    sub esp, IPC_MSG_SIZE            ; message buffer on this task's stack
    mov esi, tk_c_wait
    call print_string
    mov ebx, 5                       ; messages to receive (survives yields)
.loop:
    mov eax, esp
    push eax                         ; out
    push dword [tk_cons_pid]
    call msg_recv_wait               ; empty -> BLOCKED -> yield
    add esp, 8
    test eax, eax
    jnz .done
    mov byte [esp + IPC_M_DATA + IPC_MSG_DATA - 1], 0
    mov esi, tk_c_got
    call print_string
    lea esi, [esp + IPC_M_DATA]
    call print_string
    mov esi, tk_c_from
    call print_string
    mov eax, [esp + IPC_M_SENDER]
    call print_dec
    mov esi, tk_c_close
    call print_string
    dec ebx
    jnz .loop
.done:
    add esp, IPC_MSG_SIZE
    ret                              ; -> task_exit

tk_producer:
    mov esi, tk_p_table              ; show the consumer is really BLOCKED
    call print_string
    call task_list
    mov ebx, 0                       ; message index 0..4
.loop:
    mov eax, ebx
    shl eax, 3                       ; * 8 bytes per message string
    lea edi, [tk_msgs + eax]
    push dword 6                     ; len ("msg N" + 0)
    push edi
    push dword 1                     ; type
    push dword [tk_cons_pid]
    push dword [tk_prod_pid]
    call msg_send
    add esp, 20
    mov esi, tk_p_sent
    call print_string
    mov esi, edi
    call print_string
    call newline
    call task_yield                  ; let the consumer run
    inc ebx
    cmp ebx, 5
    jb .loop
    ret                              ; -> task_exit

task_demo:
    push tk_n_cons                   ; consumer first, so it blocks first
    push tk_consumer
    call task_create
    add esp, 8
    test eax, eax
    js .nofree
    mov [tk_cons_pid], eax
    push tk_n_prod
    push tk_producer
    call task_create
    add esp, 8
    test eax, eax
    js .nofree
    mov [tk_prod_pid], eax
    mov esi, tk_d_start
    call print_string
.wait:
    call task_yield                  ; the shell is task 0: take turns
    call tasks_alive
    cmp eax, 1
    ja .wait
    mov esi, tk_d_done
    call print_string
    ret
.nofree:
    mov esi, tk_d_nofree
    call print_string
    ret

tk_d_start   db "Started consumer and producer. Running...", 10, 0
tk_d_done    db "Demo finished: both tasks exited.", 10, 0
tk_d_nofree  db "Cannot start: no free process slots (see 'ipc status')", 10, 0

; =====================================================================
; Shell command: CF=0 handled, CF=1 not mine (same as ipc_command)
; =====================================================================
tk_k_task    db "task", 0
tk_k_demo    db "demo", 0
tk_k_list    db "list", 0
tk_help      db "=== TASKING ===", 10
             db "task demo      producer/consumer: shows blocking receive + wake-up", 10
             db "task list      show running tasks and their state", 10, 0

task_command:
    pushad
    mov esi, cmd_buf
    mov edi, tk_k_task
    call ic_word                     ; helper from msgpassing.asm
    test al, al
    jz .not_mine
    cmp byte [esi], 0
    je .help
    mov edi, tk_k_demo
    call ic_word
    test al, al
    jnz .demo
    mov edi, tk_k_list
    call ic_word
    test al, al
    jnz .list
.help:
    mov esi, tk_help
    call print_string
    jmp .handled
.demo:
    call task_demo
    jmp .handled
.list:
    call task_list
.handled:
    popad
    clc
    ret
.not_mine:
    popad
    stc
    ret