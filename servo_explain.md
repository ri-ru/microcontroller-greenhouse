# Project architecture — what R needs to know

## What the project IS, in one sentence

A state machine with two interrupt handlers around it. The state machine lives in the main loop; the two ISRs feed it events (button press from the remote, and a 1-second heartbeat from Timer0).

## The three modes

The whole program is always in one of three states stored in SRAM at `mode_var` (0x0260):

- **NORMAL** (default after boot): regulation runs, all buttons work
- **SET**: user is editing the target temperature with CH+/CH−, only those + AV/POWER respond
- **SLEEP**: everything paused — the Timer0 ISR detects this and exits immediately without reading the sensor, LCD is cleared, only POWER will wake it

The main loop just looks at `mode_var` and calls the right "do_X" routine, which checks if there's a fresh button press and acts on it.

## Who writes what to the LCD (the split)

The screen is 2×16. We split it cleanly:

| Line | Owner | Content |
|---|---|---|
| **Line 1** (top) | main loop, in `display.asm` | `Set:25C. Closed.` (or `Open.`, `<EDIT>.`, `Sleeping...`) |
| **Line 2** (bottom) | Timer0 ISR, in `thermo.asm` | `Temp: 23.50 C`, refreshed once per second |

They never touch each other's line, so the cursor never gets confused.

To stop the main loop from constantly hammering line 1, we use a "dirty" flag (`lcd_dirty`): main loop only redraws line 1 when something **changed** — a mode transition, the user pressing CH+/CH−, or the auto-control opening/closing the window. Otherwise it just returns immediately.

## The file layout (after splitting)

```
main.asm        ─ reset, vector table, main loop, mode dispatcher
ir_rc5.asm      ─ ISR for the remote (decodes one RC5 frame)
thermo.asm      ─ ISR for Timer0 (reads DS18B20, runs the auto-control)
servo.asm       ─ open_window / close_window (R fills the PWM here)
display.asm     ─ LCD line 1 + the splash screen
lcd.asm / printf.asm / wire1.asm / macros.asm / definitions.asm  ─ course libraries (untouched)
```

**Each `.asm` file = one responsibility.** `main.asm` is the skeleton; the rest are the muscles.

## The two interrupts (the "real-time" part)

1. **INT7** — when the IR receiver sees a falling edge on PE7 (= start of a remote frame), the chip jumps to `rc5_isr` in `ir_rc5.asm`. It decodes the 14-bit frame, writes the command byte to `rc5_cmd`, and sets the `rc5_new` flag. **The main loop notices `rc5_new` on its next iteration** and dispatches.

   There's also a toggle-bit filter so that holding a button doesn't fire the dispatcher 10 times per second.

2. **Timer0 overflow** — fires once per second (async mode, driven by the 32 kHz watch crystal on the board, prescaler 128). The chip jumps to `overflow0` in `thermo.asm`. It:
   - reads the temperature from the DS18B20
   - prints it on line 2
   - compares the temperature against the user's target (also stored in SRAM, so it's always up-to-date with whatever SET mode did)
   - calls `open_window` or `close_window` only if the window's current state is wrong for that temperature (edge-triggered, no flapping)

## How the ISRs and the main loop talk

**They never call each other directly.** They both poke at a handful of bytes in SRAM:

| Address | Variable | Set by | Read by |
|---|---|---|---|
| 0x0260 | `mode_var` | main loop (transitions) | both |
| 0x0261 | `target_temp` | main loop (target_up/down) | Timer0 ISR (every overflow) |
| 0x0262 | `window_open` | open/close_window | both (for state display + edge detection) |
| 0x0263 | `rc5_cmd` | RC5 ISR | main loop |
| 0x0264 | `rc5_new` | RC5 ISR (set) / main loop (clear) | main loop |
| 0x0265 | `rc5_last_tog` | RC5 ISR | RC5 ISR |
| 0x0266 | `lcd_dirty` | main loop + transitions + window changes | main loop |

That's the entire shared state. About 7 bytes.

## What boot does, in order

1. `reset:` initialises the stack, MCUCR (external SRAM bit for the LCD), the IR pin, the 1-wire bus, and the LCD itself.
2. Calls `do_splash` → "Hello gardener!" for 2 s.
3. Initialises all the SRAM state to defaults (NORMAL mode, target = 25 °C, window closed).
4. Enables INT7 (the remote), then enables Timer0 (heartbeat), then `sei`.
5. Falls into `main:` — the dispatcher loop.

## What's left for R to do

The servo PWM. `servo.asm`'s `open_window` and `close_window` currently only flip the `window_open` SRAM byte — no pulse signal goes out to PB4. To actually move the servo, the routines need ~20 pulses of (HIGH for 1 ms or 2 ms, LOW for 18 ms). The pattern is exactly what's in `docs/TP10/TP10/servo1.asm`: `P1 PORTB, SERVO1` + `WAIT_US 2000` + `P0 PORTB, SERVO1` + `WAIT_US 18000` in a loop.

Everything else is wired up and tested — when R drops in the pulse loop, the auto-control logic in `thermo.asm` will trigger it on temperature crossings, and the VOL+/VOL− remote buttons will trigger it manually.

---

That's the "story" you can tell. The interrupts handle the real-time stuff (button presses and the periodic temp read), the main loop handles the user-facing state, and the SRAM bytes are the glue.
