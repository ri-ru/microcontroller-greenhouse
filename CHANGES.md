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
