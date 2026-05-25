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

### `main.asm` — scaffolding for R's temperature ISR (no conflicts)
After R updated `wire1_temp2.asm` (still standalone, not actually being built — `.asmproj` entry is `main.asm`), I added the integration hooks to `main.asm` so R can drop her ISR body in without anything breaking:

- **Vector table:** added `.org OVF0addr` → `rjmp overflow0` (next to the existing INT7 entry).
- **`reset:`** now calls `rcall wire1_init`, loads `b3:b2 = 0x0190` (= 25 °C × 16 in DS18B20 raw format) as the comparison limit, configures Timer0 in async mode matching R's settings (`ASSR=AS0`, `TCCR0=1`, `TIMSK=TOIE0`), kicks off the first DS18B20 conversion, then `sei`.
- **`.include "wire1.asm"`** added after `printf.asm` so low-level 1-wire calls (`wire1_reset`, `wire1_write`, `wire1_read`, `skipROM`, `convertT`, …) are resolved.
- **`overflow0:` stub** added near the `open_window`/`close_window` stubs. Currently just saves/restores SREG and `reti`s. Marked with a TODO block telling R exactly what to paste in and which register-save conventions to follow (b2/b3 stay reserved, push everything else the body modifies).

`wire1_temp2.asm` was **not** modified — stays as R's standalone reference. When R is ready, she copies her ISR body into the `overflow0` stub in `main.asm` and either deletes `wire1_temp2.asm` or keeps it as a test scratch file.

**Risks / not yet handled:**
- Timer0 in async mode (`AS0=1`) requires an external 32 kHz crystal on TOSC1/TOSC2 — if the STK-300 isn't wired for it, Timer0 won't tick and `overflow0` never fires. R chose this; we'll find out at the bench.
- The async-Timer0 init order doesn't follow the datasheet's strict sequence (disable IE → set AS0 → write TCCR0 → wait for *UB bits → clear TIFR → enable IE). Matches R's order; can be tightened later if Timer0 misbehaves.
- The limit `b3:b2` is loaded once at reset, not re-loaded from `target_temp` SRAM when SET mode changes the consigne. Either R re-reads SRAM inside the ISR, or we add a notify hook in `target_up`/`target_down`. Flagged in the ISR's TODO comment.

### `REPORT.md` — new
Markdown draft of the technical report, mirroring the LaTeX section structure (Description générale / Manuel d'utilisation / Rapport technique) so V can copy-paste into `MCU2026-GXXX.tex`. Sections filled in for the work done so far (V's parts: IR/RC5, LCD, state machine). R's parts (servo, DS18B20) have `*(à compléter par R)*` placeholders.

### Vivanco UR Z2 button codes captured + remapped (V)
Plugged the kit in, ran the `last=XX` debug field on line 1 NORMAL, pressed each button and recorded the RC5 code. Mapping table is now in `main.asm` as a comment block at the top of the `KEY_*` `.equ`s.

Confirmed codes: digits `0..9` → `0x00..0x09`, `-/--` → `0x0a`, POWER → `0x0c`, MUTE → `0x0d`, VOL± → `0x10`/`0x11`, CH± → `0x20`/`0x21`, GUIDE → `0x22`, AV → `0x38`. The physical "SET" button on the remote emits nothing (it's the remote's own programming-mode button, not RC5).

Remapped `KEY_SET` from the guess `0x12` to **AV (`0x38`)** — distinct corner button, won't get confused with VOL± or CH±. All 6 game keys (SET/UP/DOWN/POWER/OPEN/CLOSE) now map to real Vivanco buttons.

### `ir_rc5.asm` — auto-repeat filter via toggle bit (V)
**Problem observed.** Every button press was firing the dispatcher twice — UP/DOWN incremented by 2, AV briefly flashed between modes, etc. Cause: an RC5 remote sends one full frame every ~114 ms while a button is held, and even a "quick tap" usually emits 2 frames (~25 ms each, 89 ms apart). The decoder was setting `rc5_new = 1` for every frame received.

**Fix.** RC5 frames contain a toggle bit (bit 11 of the 14-bit frame) that flips on each new keypress but stays the same during auto-repeat. After the 14 `ROL2 b1, b0`s of the decoder, that bit lands at `b1` bit 3. Saving it in SRAM (`rc5_last_tog`) and comparing each new frame against the saved value:

- new toggle ≠ saved → real new press → set `rc5_new`, update saved value
- new toggle = saved → button held / auto-repeat → ignore

`rc5_last_tog` initialised to `0xff` (impossible value, neither `0x00` nor `0x08`) so the very first press after reset is always treated as new.

### `main.asm` — POWER works in SET mode
Tiny UX fix: in the SET dispatcher, `KEY_POWER` was previously unhandled — pressing POWER while editing the consigne did nothing, which felt broken. Now POWER in SET goes straight to SLEEP (via `to_sleep`), same as POWER in NORMAL. SET → NORMAL via AV still works as before.

### `main.asm` — temperature ISR integration + LCD line-split (V, integrating R's code)
R's `wire1_temp2.asm` had a working temperature-read flow but was still a standalone program with its own `reset`/`main`. The body of her `overflow0` is now folded into `main.asm` as the real Timer0 ISR.

**LCD ownership split** to prevent the ISR and the main loop from fighting over the cursor:
- **Line 1** is owned by `overflow0` — `LCD_home` + `PRINTF "temp=XX.YY C"` (R's exact print statement, intact).
- **Line 2** is owned by `lcd_refresh` — mode-specific status, written via `LCD_lf` (no `LCD_home`, no `LF`, so it never touches line 1).

**Dirty-flag throttling (`lcd_dirty` at 0x0266).** Without it, the main loop would PRINTF line 2 on every iteration (thousands of times per second), and ~1 ms of LCD-write time per refresh would almost always overlap with the ISR's line-1 write → cursor races → trashed temp display. With the flag, line 2 is only redrawn when something actually changed:
- on every state transition (`to_normal` / `to_set` / `to_sleep`)
- on consigne change (`target_up` / `target_down`)
- on window change (`open_window` / `close_window`, whether called from RC5 path or from the ISR's auto-control)
- forced to 1 in `reset` so the first frame is drawn

`lcd_refresh` checks the flag, clears it, then dispatches to one `show_*` per mode. Otherwise it returns immediately.

**Window auto-control logic (in `overflow0`).** Skipped entirely when `mode_var == MODE_SLEEP` (sleep means no regulation, window stays closed). Otherwise:
```
b1:b0 = temp - consigne   (DS18B20 raw 16-bit, signed)
if N flag set  (temp < consigne):  close_window if currently open
else           (temp >= consigne): open_window  if currently closed
```
Edge-triggered: only acts when the state actually needs to change, so we don't pointlessly call the servo routine on every overflow. The fix repairs R's window logic, which had:
1. Both `rcall open_window` lines commented out as `nop;rcall ...` (the `;` is end-of-line comment → `rcall` never executed)
2. The "close" branch also written as `rcall open_window` (copy-paste typo)
3. `bst b1, 7` reading bit 7 of uninitialised `b1` as a supposed "is window closed" flag

**ISR register saves.** R's standalone version didn't need to save anything because her `main: rjmp main` didn't use any registers. In our integrated version the ISR's body (LCD/PRINTF/wire1) clobbers most caller-saved registers, so the ISR now pushes `w, u, char, e0, e1, c0, a0..a3, b0, b1, X, Y, Z` and pops them on exit. `b2`/`b3` (the consigne) are intentionally **not** pushed — they hold persistent state set once in reset.

**`show_*` rewritten** for 16-char line-2-only output:
- NORMAL: `set=25 win=0    `
- SET:    `SET target=25 dC`
- SLEEP:  `SLEEP win closed`

The `last=XX` debug field used for button-code capture is removed (its job is done — the mapping is in the `KEY_*` `.equ`s).

**`wire1_temp2.asm` is left untouched** — kept as R's reference / scratchpad. The actual build only uses `main.asm`'s `overflow0`.

### `main.asm` — consigne re-loaded from SRAM each ISR
Previously the ISR compared the temperature against `b3:b2`, which was set once in `reset` to `25 × 16` and never updated — so changing the target in SET mode had no effect on the auto-regulation. Fixed by deleting the boot-time `ldi b2, … / ldi b3, …` and recomputing `b3:b2 = target_temp * 16` inside `overflow0` each time, right after the SLEEP-mode skip and before the threshold compare. Four `lsl b2 / rol b3` pairs do the ×16. `b2` and `b3` are now scratch registers from the ISR's perspective, so they're added to the push/pop list.

### Note on PRINTF `$42`
Earlier change-log entry called this a cosmetic bug ("'B' as decimal separator"). It is not — `_putfrac` interprets that byte as the **ii.ff format spec** (high nibble = integer digits, low nibble = fraction digits), not as a literal character. The decimal point itself is inserted by the formatter. The display will read something like `temp=  25.00C `, no rogue character.

### `main.asm` — UX polish (splash + readable line 2)
- 3-second splash on boot showing `Hello gardener!` on line 1. Inserted in `reset` right after `LCD_init`, blocking via `WAIT_MS 3000` and cleared with `LCD_clear` before Timer0/INT7 are enabled (so neither ISR can stomp the splash).
- Line 1 (`overflow0`) reformatted: `temp=…` → `Temp:  XX.XX C  ` (using `$22` ii.ff so the integer part is 2 digits instead of 4, fits cleanly in 16 chars).
- Line 2 (`show_*` routines) reads in plain English instead of cryptic shorthand:
  - **NORMAL**: `Set:25C Closed  ` or `Set:25C Open    ` (branches on `window_open`)
  - **SET**:    `Set:25C <EDIT>  `
  - **SLEEP**:  `Sleeping...     `

`show_normal` now has two `.db` lines (one for closed, one for open) — selected by an early `lds w, window_open / tst / brne show_normal_open`. Both stay at 16 chars to fully overwrite the previous content.

### `main.asm` — fix: preserve temperature across PRINTF in overflow0
Bug: changing the target in SET mode didn't actually update the window — e.g. with temp=28 °C and target=25, the window stayed `Closed` instead of auto-opening.

Cause: `PRINTF` with `FFRAC2` modifies `a0..a3` while formatting (sign-extension, divide-by-10 per digit, etc.). The ISR read the temperature into `a1:a0`, printed it with `PRINTF "Temp: …,a,…"`, then did the threshold compare via `mov b0, a0 / mov b1, a1` — except by then `a1:a0` was garbage from PRINTF, not the real temperature. The compare was effectively comparing random bits against the consigne, giving a random N flag and a random open/close decision.

Fix: push `a0` / `a1` before the PRINTF call and pop them back afterwards (after the convertT trigger). The threshold compare further down now reads the true measured temperature.

### `main.asm` — line 2 cosmetics: dots after value and state
`Set:25C Closed  ` → `Set:25C. Closed.` (and similarly `Set:25C. Open.  ` / `Set:25C. <EDIT>.`). Easier to parse visually. All still padded to exactly 16 chars so each frame fully overwrites the previous.

### Known remaining issues
- `open_window` / `close_window` still only flip the `window_open` SRAM byte. R has to wire up the servo PWM on PORTB.4 (M4) to make the window physically move.
