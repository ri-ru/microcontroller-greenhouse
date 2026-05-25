# Changes

## Final state (2026-05-25, veille du rendu)

**Architecture livrée :** machine à états en boucle principale,
alimentée par deux ISR (INT7 pour la télécommande, Timer0 pour la
température). Communication par variables partagées en SRAM, jamais par
appel direct entre ISR et boucle.

**Modules :**

| Fichier            | Compilé ? | Rôle |
| ------------------ | --------- | ---- |
| `main.asm`         | oui (entrée Atmel Studio) | reset, table des vecteurs, boucle principale, machine à états (`dispatch`, `do_normal/set/sleep`, transitions, `target_up/down`) |
| `ir_rc5.asm`       | oui (`.include`) | ISR INT7 — décodage RC5 + filtre toggle |
| `thermo.asm`       | oui (`.include`) | ISR Timer0 — lecture DS18B20, affichage ligne 2, seuil → fenêtre |
| `servo.asm`        | oui (`.include`) | `open_window` / `close_window` (corps PWM à compléter par R) |
| `display.asm`      | oui (`.include`) | `lcd_refresh`, `show_*`, `do_splash` |
| `lcd.asm`          | oui (`.include`, fourni) | pilote HD44780U |
| `printf.asm`       | oui (`.include`, fourni) | impression formatée |
| `wire1.asm`        | oui (`.include`, fourni) | pilote 1-wire bas niveau |
| `macros.asm`       | oui (`.include`, fourni) | macros AVR |
| `definitions.asm`  | oui (`.include`, fourni) | registres, ports, constantes |
| `wire1_temp2.asm`  | non | programme de test autonome de R, conservé comme référence |
| `buzzer_sniffer.asm`, `ir_sniffer.asm` | non | diagnostics IR utilisés pendant le développement |
| `led0.asm`, `printf1.asm` | non | helpers/variantes non utilisés dans l'app finale |

**Mappage SRAM (0x0260+, plage compatible PRINTF) :**

| addr   | symbole         | rôle                                            |
| ------ | --------------- | ----------------------------------------------- |
| 0x0260 | `mode_var`      | 0=NORMAL, 1=SET, 2=SLEEP                        |
| 0x0261 | `target_temp`   | consigne en °C (5..40)                          |
| 0x0262 | `window_open`   | 0=fermée, 1=ouverte                             |
| 0x0263 | `rc5_cmd`       | dernier code RC5 décodé                         |
| 0x0264 | `rc5_new`       | 1 = nouvelle commande RC5 en attente            |
| 0x0265 | `rc5_last_tog`  | dernier bit toggle (filtre auto-répétition RC5) |
| 0x0266 | `lcd_dirty`     | 1 = ligne d'état LCD à redessiner               |

**Points encore ouverts :**

- `open_window` / `close_window` dans `servo.asm` ne mettent que le
  drapeau `window_open` à jour. R doit y câbler la commande PWM du servo
  Futaba S3003 sur PB4 (suivre `docs/TP10/TP10/servo1.asm`).
- Test final sur établi (sensor + servo + télécommande sur la même
  carte). Tout a été testé séparément.

---

## Journal de développement

### 2026-05-25

#### Repo cleanup
- Added `.gitignore`: course PDFs (`docs/`, `Starting package/`, `Libraries_128L-4MHz/`, `project_guidelines.pdf`), Atmel build output (`Debug/`, `*.obj`, `*.hex`, etc.), local helper files.
- Added the Atmel Studio project folder to git: `Projet_Microcontrolleurs/`.
- Removed root-level `.asm` duplicates. Single source of truth is now `Projet_Microcontrolleurs/Projet_Microcontrolleurs/`. R's latest `wire1_temp2.asm` was synced into the folder before deletion (nothing lost).

#### `main.asm` — state-machine skeleton (V)
Rewrote from the LCD "HI !" smoke test into the greenhouse state machine.

**Architecture:** polling main loop. `main` calls `poll_rc5 → dispatch → lcd_refresh` and loops. Polling chosen over ISR-driven for the dispatch level because the RC5 decoder already busy-waits inside one frame (~25 ms) and the temp / servo cadence is slow — interrupts buy nothing here and the cooperative loop is easier to reason about for a 4-week project. (Forum, 22.05: both polling and interrupts accepted, justification required.)

**Modes:**
- **NORMAL** — RC5 `KEY_SET` enters SET, `KEY_POWER` enters SLEEP, `KEY_OPEN` / `KEY_CLOSE` manually moves window. R's auto temp→servo control hooks in here.
- **SET** — RC5 `KEY_UP` / `KEY_DOWN` adjusts `target_temp` (clamped), `KEY_SET` returns to NORMAL.
- **SLEEP** — only `KEY_POWER` wakes. Entering SLEEP forces window closed.

**LCD:** 3 `show_*` routines, padded to 16 chars per line so each frame fully overwrites the previous.

**Stubs left:**
- `poll_rc5` — V: hook RC5 decoder, write `rc5_cmd` + set `rc5_new`.
- `open_window` / `close_window` — R: drive the servo (PORTB.4, SERVO1).

**Placeholders:** `KEY_*` button codes at the top of `main.asm` are guesses — replace with values captured from the Vivanco UR Z2 when the kit is in hand.

#### `ir_rc5.asm` — refactored from standalone program to ISR (V)
Was a standalone test program with its own `reset:`/`main:` printing `cmd=XX` on the LCD. Now provides just `rc5_isr`, included by `main.asm`.

- Triggered by **INT7 on PE7 falling edge** (the IR receiver idles high; start of an RC5 frame = falling edge).
- Reuses the existing Manchester decode (CLR2 / ROL2 / P2C, T1=1870 µs sampling at 1/4 period then every T1).
- Removes `WP1 PINE,IR` (no longer needed: the first edge already triggered the interrupt).
- Writes the decoded byte to `rc5_cmd`, sets `rc5_new = 1`.
- Explicitly clears `INTF7` before `reti` because mid-bit Manchester transitions arm it during the decode.
- Saves/restores SREG (via `_sreg`/r1) + `w`, `u`, `b0..b2`.

#### `main.asm` — INT7 setup, `poll_rc5` removed
- Added `.org INT7addr` → `rjmp rc5_isr`.
- In `reset`: PE7 as input no-pull-up, `EICRB ← (1<<ISC71)` (falling edge), `EIFR ← (1<<INTF7)` (clear pending), `EIMSK ← (1<<INT7)`, `sei`.
- `.include "ir_rc5.asm"` added after `printf.asm`.
- Removed `poll_rc5` stub and its call from main loop (ISR sets `rc5_new` directly, no polling routine needed).

#### Architecture note — why interrupt-driven RC5
Forum (22.05) accepts polling or interrupts with justification. For the IR decoder, INT7 is clearly the right pick: without it, the main loop would have to busy-wait on PE7 continuously, blocking the LCD refresh and the temp-reading cadence. With INT7, the ~25 ms decode runs only when a button is pressed, which is rare relative to the 750 ms DS18B20 conversion cycle, so it doesn't disturb anything. The main loop itself stays cooperative polling (consuming the `rc5_new` flag) — clean separation between event capture (ISR) and event dispatch (main).

#### `main.asm` — debug: show last RC5 code on LCD (NORMAL mode)
Line 1 of NORMAL mode reads `NORMAL  last=XX` where `XX` is the last decoded RC5 byte in hex. Used to capture the actual codes for SET / CH± / VOL± / POWER on the Vivanco UR Z2: press each button, write down the value shown, replace the `KEY_*` `.equ`s at the top of `main.asm`. Removed for the final demo (it was a debug aid, not production UI).

`rc5_cmd` is initialised to 0 in reset so the field reads `00` before any button is pressed instead of garbage.

#### `main.asm` — scaffolding for R's temperature ISR (no conflicts)
After R updated `wire1_temp2.asm` (still standalone, not actually being built — `.asmproj` entry is `main.asm`), I added the integration hooks to `main.asm` so R could drop her ISR body in without anything breaking:

- **Vector table:** added `.org OVF0addr` → `rjmp overflow0` (next to the existing INT7 entry).
- **`reset:`** now calls `rcall wire1_init`, loads `b3:b2 = 0x0190` (= 25 °C × 16 in DS18B20 raw format) as the comparison limit, configures Timer0 in async mode matching R's settings (`ASSR=AS0`, `TCCR0=1`, `TIMSK=TOIE0`), kicks off the first DS18B20 conversion, then `sei`.
- **`.include "wire1.asm"`** added after `printf.asm` so low-level 1-wire calls (`wire1_reset`, `wire1_write`, `wire1_read`, `skipROM`, `convertT`, …) are resolved.
- **`overflow0:` stub** added near the `open_window`/`close_window` stubs. Currently just saves/restores SREG and `reti`s. Marked with a TODO block telling R exactly what to paste in and which register-save conventions to follow (b2/b3 stay reserved, push everything else the body modifies).

`wire1_temp2.asm` was **not** modified — stays as R's standalone reference.

#### Vivanco UR Z2 button codes captured + remapped (V)
Plugged the kit in, ran the `last=XX` debug field on line 1 NORMAL, pressed each button and recorded the RC5 code. Mapping table is now in `main.asm` as a comment block at the top of the `KEY_*` `.equ`s.

Confirmed codes: digits `0..9` → `0x00..0x09`, `-/--` → `0x0a`, POWER → `0x0c`, MUTE → `0x0d`, VOL± → `0x10`/`0x11`, CH± → `0x20`/`0x21`, GUIDE → `0x22`, AV → `0x38`. The physical "SET" button on the remote emits nothing (it's the remote's own programming-mode button, not RC5).

Remapped `KEY_SET` from the guess `0x12` to **AV (`0x38`)** — distinct corner button, won't get confused with VOL± or CH±. All 6 game keys (SET/UP/DOWN/POWER/OPEN/CLOSE) now map to real Vivanco buttons.

#### `ir_rc5.asm` — auto-repeat filter via toggle bit (V)
**Problem observed.** Every button press was firing the dispatcher twice — UP/DOWN incremented by 2, AV briefly flashed between modes, etc. Cause: an RC5 remote sends one full frame every ~114 ms while a button is held, and even a "quick tap" usually emits 2 frames (~25 ms each, 89 ms apart). The decoder was setting `rc5_new = 1` for every frame received.

**Fix.** RC5 frames contain a toggle bit (bit 11 of the 14-bit frame) that flips on each new keypress but stays the same during auto-repeat. After the 14 `ROL2 b1, b0`s of the decoder, that bit lands at `b1` bit 3. Saving it in SRAM (`rc5_last_tog`) and comparing each new frame against the saved value:

- new toggle ≠ saved → real new press → set `rc5_new`, update saved value
- new toggle = saved → button held / auto-repeat → ignore

`rc5_last_tog` initialised to `0xff` (impossible value, neither `0x00` nor `0x08`) so the very first press after reset is always treated as new.

#### `main.asm` — POWER works in SET mode
Tiny UX fix: in the SET dispatcher, `KEY_POWER` was previously unhandled — pressing POWER while editing the consigne did nothing, which felt broken. Now POWER in SET goes straight to SLEEP (via `to_sleep`), same as POWER in NORMAL. SET → NORMAL via AV still works as before.

#### `main.asm` — temperature ISR integration + LCD line-split (V, integrating R's code)
R's `wire1_temp2.asm` had a working temperature-read flow but was still a standalone program with its own `reset`/`main`. The body of her `overflow0` is folded into `main.asm` as the real Timer0 ISR.

**LCD ownership split** to prevent the ISR and the main loop from fighting over the cursor:
- **Line 1** owned by `lcd_refresh` (was line 2 originally — swapped later for readability).
- **Line 2** owned by `overflow0` — written via `LCD_lf` (no `LCD_home`, no `LF`, so it never touches line 1).

**Dirty-flag throttling (`lcd_dirty` at 0x0266).** Without it, the main loop would PRINTF on every iteration (thousands of times per second), and ~1 ms of LCD-write time per refresh would almost always overlap with the ISR's line write → cursor races → trashed temp display. With the flag, the status line is only redrawn when something actually changed:
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
Edge-triggered: only acts when the state actually needs to change, so we don't pointlessly call the servo routine on every overflow. The fix repairs R's original window logic, which had:
1. Both `rcall open_window` lines commented out as `nop;rcall ...` (the `;` is end-of-line comment → `rcall` never executed)
2. The "close" branch also written as `rcall open_window` (copy-paste typo)
3. `bst b1, 7` reading bit 7 of uninitialised `b1` as a supposed "is window closed" flag

**ISR register saves.** R's standalone version didn't need to save anything because her `main: rjmp main` didn't use any registers. In our integrated version the ISR's body (LCD/PRINTF/wire1) clobbers most caller-saved registers, so the ISR now pushes `w, u, char, e0, e1, c0, a0..a3, b0..b3, X, Y, Z` and pops them on exit.

**`wire1_temp2.asm` is left untouched** — kept as R's reference / scratchpad.

#### `main.asm` — consigne re-loaded from SRAM each ISR
Previously the ISR compared the temperature against `b3:b2`, which was set once in `reset` to `25 × 16` and never updated — so changing the target in SET mode had no effect on the auto-regulation. Fixed by deleting the boot-time `ldi b2, … / ldi b3, …` and recomputing `b3:b2 = target_temp * 16` inside `overflow0` each time, right after the SLEEP-mode skip and before the threshold compare. Four `lsl b2 / rol b3` pairs do the ×16. `b2` and `b3` are now scratch registers from the ISR's perspective, so they're added to the push/pop list.

#### Note on PRINTF `$22`
The byte after the format-spec letter in `PRINTF "Temp: ",FFRAC2+FSIGN,a,4,$22," C "` is the **ii.ff format spec** (high nibble = integer digits, low nibble = fraction digits), not a literal character. The decimal point itself is inserted by the formatter. The display reads cleanly as `Temp: 23.50 C`.

#### `main.asm` — UX polish (splash + readable lines)
- 2-second splash on boot showing `Hello gardener!` on line 1. Inserted in `reset` right after `LCD_init`, blocking via `WAIT_MS 2000` and cleared with `LCD_clear` before Timer0/INT7 are enabled (so neither ISR can stomp the splash).
- Line 2 (`overflow0`) reformatted: `temp=…` → `Temp: XX.XX C  ` (using `$22` ii.ff so the integer part is 2 digits instead of 4, fits cleanly in 16 chars).
- Line 1 (`show_*` routines) reads in plain English instead of cryptic shorthand:
  - **NORMAL**: `Set:25C. Closed.` or `Set:25C. Open.  ` (branches on `window_open`)
  - **SET**:    `Set:25C. <EDIT>.`
  - **SLEEP**:  `Sleeping...     `

#### `main.asm` — fix: preserve temperature across PRINTF in overflow0
Bug: changing the target in SET mode didn't actually update the window — e.g. with temp=28 °C and target=25, the window stayed `Closed` instead of auto-opening.

Cause: `PRINTF` with `FFRAC2` modifies `a0..a3` while formatting (sign-extension, divide-by-10 per digit, etc.). The ISR read the temperature into `a1:a0`, printed it with `PRINTF "Temp: …,a,…"`, then did the threshold compare via `mov b0, a0 / mov b1, a1` — except by then `a1:a0` was garbage from PRINTF, not the real temperature. The compare was effectively comparing random bits against the consigne, giving a random N flag and a random open/close decision.

Fix: push `a0` / `a1` before the PRINTF call and pop them back afterwards (after the convertT trigger). The threshold compare further down now reads the true measured temperature.

#### `main.asm` — line swap + wake-from-SLEEP polish
- Swapped LCD lines: state info on top (line 1), temperature on bottom (line 2). Easier to read at a glance.
- Wake-from-SLEEP now replays the `Hello gardener!` splash via the shared `do_splash` routine. Timer0 is temporarily masked (`OUTI TIMSK, 0`) so the ISR can't write the temperature on top of the splash, then re-enabled.
- SLEEP "goodbye": prints `Sleeping...` for 2 s then `LCD_clear`s — the display stays powered but visually blank. Simpler than turning the LCD off (no wake-stuck-display issues).

#### `main.asm` split into modules — `servo.asm`, `thermo.asm`, `display.asm`
Carved up the single monolithic `main.asm` so each functional concern lives in its own file. **Zero behavior change** — purely a relocation of code blocks, byte-for-byte identical assembled output.

**New file layout:**
| File | Contains | Notes |
|---|---|---|
| `main.asm` | header, `.equ`s, vector table, `.include` block, `reset:`, `main:`, `dispatch`, `do_normal/set/sleep`, transitions, `target_up/down` | ~210 lines (down from ~400) |
| `servo.asm` | `open_window`, `close_window` | R fills the PWM implementation here |
| `thermo.asm` | `overflow0` (Timer0 ISR: DS18B20 read, line-2 PRINTF, threshold logic) | replaces the in-place stub in `main.asm` |
| `display.asm` | `lcd_refresh`, `show_normal/set/sleep`, `do_splash` | LCD-side concerns |

**Include order in `main.asm`:**
1. Drivers fournis : `lcd.asm` → `printf.asm` → `wire1.asm`
2. Modules applicatifs : `ir_rc5.asm` → `servo.asm` → `thermo.asm`
3. Affichage : `display.asm`

Drivers first because everything depends on them; `servo.asm` before `thermo.asm` because `overflow0` (in `thermo.asm`) calls `open_window`/`close_window` (forward refs would work too, but bottom-up reads cleaner); `display.asm` last because it's only referenced from `reset:` and `main:` of `main.asm`.

**`.asmproj` updated** to list `servo.asm`, `thermo.asm`, `display.asm` so AS7 shows them in the Solution Explorer tree.

**Rationale.** The original `main.asm` had grown past 400 lines covering ~6 distinct responsibilities; splitting along the natural seams gives V and R clean ownership boundaries (V owns `display.asm` and the LCD details, R owns `servo.asm` and the body of `thermo.asm`) and reduces the chance of merge conflicts. Also makes the project layout match the *présentation des modules* table in the report — "one fichier par responsibility" reads better than "everything in main.asm".

#### `REPORT.md`, `CHANGES.md`, `video_script.md` — final pass
Aligned all three documents on the post-split structure: module table updated, file references corrected, narrative streamlined. CHANGES.md gained a "Final state" section at the top so a reader can pick up the project without reading the full chronological log.
