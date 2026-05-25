# Changes

## 2026-05-25

### Repo cleanup
- Added `.gitignore`: course PDFs (`docs/`, `Starting package/`, `Libraries_128L-4MHz/`, `project_guidelines.pdf`), Atmel build output (`Debug/`, `*.obj`, `*.hex`, etc.), local helper files.
- Added the Atmel Studio project folder to git: `Projet_Microcontrolleurs/`.
- Removed root-level `.asm` duplicates. Single source of truth is now `Projet_Microcontrolleurs/Projet_Microcontrolleurs/`. R's latest `wire1_temp2.asm` was synced into the folder before deletion (nothing lost).

### `main.asm` — state-machine skeleton (V)
Rewrote from the LCD "HI !" smoke test into the greenhouse state machine.

**Architecture:** polling main loop. `main` calls `poll_rc5 → dispatch → lcd_refresh` and loops. Polling chosen over ISR-driven for the dispatch level because the RC5 decoder already busy-waits inside one frame (~25 ms) and the temp / servo cadence is slow — interrupts buy nothing here and the cooperative loop is easier to reason about for a 4-week project. (Forum, 22.05: both polling and interrupts accepted, justification required.)

**State (SRAM 0x0260+):**
| addr   | name          | meaning                         |
|--------|---------------|---------------------------------|
| 0x0260 | `mode_var`    | 0=NORMAL, 1=SET, 2=SLEEP        |
| 0x0261 | `target_temp` | consigne en °C (5..40)          |
| 0x0262 | `window_open` | 0=closed, 1=open                |
| 0x0263 | `rc5_cmd`     | last decoded RC5 command byte   |
| 0x0264 | `rc5_new`     | 1 = fresh cmd waiting for main  |

**Modes:**
- **NORMAL** — RC5 `KEY_SET` enters SET, `KEY_POWER` enters SLEEP, `KEY_OPEN` / `KEY_CLOSE` manually moves window. R's auto temp→servo control hooks in here.
- **SET** — RC5 `KEY_UP` / `KEY_DOWN` adjusts `target_temp` (clamped), `KEY_SET` returns to NORMAL.
- **SLEEP** — only `KEY_POWER` wakes. Entering SLEEP forces window closed.

**LCD:** 3 `show_*` routines, padded to 16 chars per line so each frame fully overwrites the previous.

**Stubs left:**
- `poll_rc5` — V: hook RC5 decoder, write `rc5_cmd` + set `rc5_new`.
- `open_window` / `close_window` — R: drive the servo (PORTB.4, SERVO1).

**Placeholders:** `KEY_*` button codes at the top of `main.asm` are guesses — replace with values captured from the Vivanco UR Z2 when the kit is in hand.

### Build status
- Atmel Studio entry point unchanged: `Projet_Microcontrolleurs.asmproj` → `main.asm`.
- `main.asm` includes only `macros.asm`, `definitions.asm`, `lcd.asm`, `printf.asm`. Does **not** include `wire1*.asm` yet (R's `wire1_temp2.asm` still has its own `reset:` — integration TBD).
- Not yet test-assembled in Atmel Studio.

### `ir_rc5.asm` — refactored from standalone program to ISR (V)
Was a standalone test program with its own `reset:`/`main:` printing `cmd=XX` on the LCD. Now provides just `rc5_isr`, included by `main.asm`.

- Triggered by **INT7 on PE7 falling edge** (the IR receiver idles high; start of an RC5 frame = falling edge).
- Reuses the existing Manchester decode (CLR2 / ROL2 / P2C, T1=1870 µs sampling at 1/4 period then every T1).
- Removes `WP1 PINE,IR` (no longer needed: the first edge already triggered the interrupt).
- Writes the decoded byte to `rc5_cmd`, sets `rc5_new = 1`.
- Explicitly clears `INTF7` before `reti` because mid-bit Manchester transitions arm it during the decode.
- Saves/restores SREG (via `_sreg`/r1) + `w`, `u`, `b0..b2`.

### `main.asm` — INT7 setup, `poll_rc5` removed
- Added `.org INT7addr` → `rjmp rc5_isr`.
- In `reset`: PE7 as input no-pull-up, `EICRB ← (1<<ISC71)` (falling edge), `EIFR ← (1<<INTF7)` (clear pending), `EIMSK ← (1<<INT7)`, `sei`.
- `.include "ir_rc5.asm"` added after `printf.asm`.
- Removed `poll_rc5` stub and its call from main loop (ISR sets `rc5_new` directly, no polling routine needed).

### Why interrupt-driven RC5 (architecture note)
Forum (22.05) accepts polling or interrupts with justification. For the IR decoder, INT7 is clearly the right pick: without it, the main loop would have to busy-wait on PE7 continuously, blocking the LCD refresh and the temp-reading cadence. With INT7, the ~25 ms decode runs only when a button is pressed, which is rare relative to the 750 ms DS18B20 conversion cycle, so it doesn't disturb anything. The main loop itself stays cooperative polling (consuming `rc5_new` flag) — clean separation between event capture (ISR) and event dispatch (main).

### `main.asm` — debug: show last RC5 code on LCD (NORMAL mode)
Line 1 of NORMAL mode now reads `NORMAL  last=XX` where `XX` is the last decoded RC5 byte in hex. Use this to capture the actual codes for SET / CH± / VOL± / POWER on the Vivanco UR Z2: press each button, write down the value shown, replace the `KEY_*` `.equ`s at the top of `main.asm`, then **remove the `last=` field** for the final demo (it's a debug aid, not production UI).

`rc5_cmd` is now initialised to 0 in reset so the field reads `00` before any button is pressed instead of garbage.

### `REPORT.md` — new
Markdown draft of the technical report, mirroring the LaTeX section structure (Description générale / Manuel d'utilisation / Rapport technique) so V can copy-paste into `MCU2026-GXXX.tex`. Sections filled in for the work done so far (V's parts: IR/RC5, LCD, state machine). R's parts (servo, DS18B20) have `*(à compléter par R)*` placeholders.
