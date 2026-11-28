# Part 3 - Interrupt-Driven I/O: test plan and notes

| # | Feature | How to test | Expected | Actual | P/F |
|---|---|---|---|---|---|
| 1 | IDT/PIC/PIT/KBD init | boot | four `[ OK ]` lines, then prompt | | |
| 2 | Timer | `ticks`, wait, `ticks` again | ticks +100 per real second | | |
| 3 | Keyboard | type, use Shift and Backspace | echo, capitals/symbols, erase works | | |
| 4 | Buffer | type while running `alloc A 1M` | no lost keys | | |
| 5 | IRQ counters | `irqstat` | IRQ0 and IRQ1 counts increase | | |
| 6 | I/O map | `iomap` | PIT and Keyboard rows | | |
| 7 | #BP | `int3` | message, shell keeps working | | |
| 8 | #DE | `div0` | "Divide Error (#DE)" report, halt | | |
| 9 | Allocator unaffected | `alloc`/`free`/`dump` | same as before Part 3 | | |

## Notes for the report
* EOI is sent after the handler returns. When the scheduler switches tasks from the timer
  (milestone 10), send the EOI before the switch.
* `sched_hook` (pit.asm) and `kbd_msg_hook` (keyboard.asm) are the attachment points for
  the scheduler and ISR-to-task messaging.
* Typical bugs worth journaling: missing PIC remap (IRQ0 lands on the #DF vector), missing
  EOI (timer stops after one tick), wrong code selector in a gate (#GP -> triple fault).
