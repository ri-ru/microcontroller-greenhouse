# Flowchart source — for app.diagrams.net

One section per routine. Each routine = one rounded box on the diagram with:
- **In:** parameter chip (top-left)
- short body of what it does
- arrows out to the routines it calls

Only the code **we** wrote is documented here. Pre-given libraries (`lcd.asm`,
`printf.asm`, `wire1.asm`, `macros.asm`, `definitions.asm`, `led0.asm`) are
treated as black boxes — draw them as plain rectangles without internals.

---

## Shared SRAM state (central box on the diagram)

Drawn as one rectangle in the middle of the page. All ISRs and the main loop
communicate through it.

```
mode_var       NORMAL / SET / SLEEP / HISTORY
target_temp    consigne 5..40 °C
window_open    0 = closed, 1 = open
rc5_cmd        last decoded RC5 command
rc5_new        flag: 1 = fresh command waiting
rc5_last_tog   last RC5 toggle bit (auto-repeat filter)
lcd_dirty      flag: 1 = line 1 must be redrawn
min_temp (16b) SRAM mirror of EEPROM min
max_temp (16b) SRAM mirror of EEPROM max
```

---

# Lane 1 — Boot (`reset`)

## `reset`
- **In:** (none, power-on)
- Init stack, enable external SRAM, IR pin as input.
- Call `wire1_init`, `LCD_init`, `history_init`, `do_splash`.
- Init SRAM state (mode=NORMAL, target=25, window=0, dirty=1).
- Enable INT7 (RC5), Timer0 overflow (~1 Hz).
- Launch first DS18B20 `convertT`.
- `rjmp main`.
- **Calls:** `history_init`, `do_splash`, then jumps to `main`.

---

# Lane 2 — Main loop (foreground)

## `main`
- **In:** (none)
- Endless loop: `dispatch` → `lcd_refresh` → repeat.
- **Calls:** `dispatch`, `lcd_refresh`.

## `dispatch`
- **In:** `mode_var`
- 4-way switch on current mode.
- **Calls:** `do_normal` / `do_set` / `do_sleep` / `do_history`.

## `do_normal`
- **In:** `rc5_new`, `rc5_cmd`
- If a fresh RC5 command is waiting, branch on the key code.
- Clears `rc5_new` after handling.
- **Calls:** `to_set` (AV), `to_sleep` (POWER), `open_window` (VOL+),
  `close_window` (VOL−), `to_history` (GUIDE).

## `do_set`
- **In:** `rc5_new`, `rc5_cmd`
- **Calls:** `to_normal` (AV), `to_sleep` (POWER),
  `target_up` (CH+), `target_down` (CH−).

## `do_sleep`
- **In:** `rc5_new`, `rc5_cmd`
- Only POWER reacts.
- **Calls:** `to_normal`.

## `do_history`
- **In:** `rc5_new`, `rc5_cmd`
- **Calls:** `to_normal` (GUIDE), `to_sleep` (POWER).

---

## Mode transitions

## `to_normal`
- **In:** old `mode_var`
- If from SLEEP → re-run `do_splash` (with Timer0 suspended).
- If from HISTORY → `LCD_clear` so "Max:" doesn't linger on line 2.
- Else (from SET) → just set mode + dirty.
- **Calls:** `do_splash` (sleep case), `LCD_clear` (history case).

## `to_set`
- Sets `mode_var = SET`, `lcd_dirty = 1`.

## `to_history`
- Sets `mode_var = HISTORY`, `lcd_dirty = 1`.

## `to_sleep`
- Sets `mode_var = SLEEP`.
- `close_window` (force shut).
- Print "Sleeping..." for 2 s, then `LCD_clear`.
- `lcd_dirty = 0` (nothing should redraw while sleeping).
- **Calls:** `close_window`.

## `target_up`
- **In:** `target_temp`
- Clamp 40, otherwise increment, set `lcd_dirty`.

## `target_down`
- **In:** `target_temp`
- Clamp 5, otherwise decrement, set `lcd_dirty`.

---

## `lcd_refresh` (display.asm)

## `lcd_refresh`
- **In:** `lcd_dirty`, `mode_var`
- If `lcd_dirty == 0` → return.
- Else clear flag, branch on mode.
- **Calls:** `show_normal` / `show_set` / `show_sleep` / `show_history`.

## `show_normal`
- **In:** `target_temp`, `window_open`
- Line 1 = `"Set:XXC. Closed."` or `"Set:XXC. Open.  "`.

## `show_set`
- **In:** `target_temp`
- Line 1 = `"Set:XXC. <EDIT>."`.

## `show_sleep`
- Line 1 = `"Sleeping...     "`.

## `show_history`
- **In:** `min_temp`, `max_temp` (SRAM mirror)
- Line 1 = `"Min:±XX.XX C"`, line 2 = `"Max:±XX.XX C"`.
- The only `show_*` that writes to line 2 (overrides `overflow0`).

## `do_splash`
- Print `"Hello gardener!"` for 2 s, then `LCD_clear`.
- Called from `reset` (boot) and `to_normal` (wake-from-SLEEP).

---

# Lane 3 — Timer0 ISR (~1 Hz)

## `overflow0` (thermo.asm)
- **In:** triggered by Timer0 overflow (vector OVF0addr)
- Save SREG.
- If `mode == SLEEP` → reti immediately.
- Push all registers PRINTF / wire1 will clobber.
- If `mode != HISTORY` → `LCD_lf` (cursor to line 2).
- Read DS18B20 scratchpad → `a1:a0` = temperature (raw 16-bit signed).
- If `mode != HISTORY` → `PRINTF "Temp: XX.XX C"` on line 2.
- Launch next `convertT`.
- `history_update` (may write EEPROM if new extreme).
- If `mode == HISTORY` → skip regulation, return.
- Build `b3:b2 = target_temp << 4` (DS18B20-format consigne).
- Compare temp vs consigne (signed 16-bit):
  - `temp >= consigne` and window closed → `open_window`.
  - `temp <  consigne` and window open  → `close_window`.
- Restore all registers, reti.
- **Calls:** `history_update`, `open_window`, `close_window`.

---

# Lane 4 — INT7 ISR (RC5 falling edge on PE7)

## `rc5_isr` (ir_rc5.asm)
- **In:** triggered by INT7 falling edge
- Wait `T1/4` (sample at the middle of the bit).
- Loop 14×: read PE7 into carry, rotate into `b1:b0`, wait `T1`.
- `com b0` (RC5 inverse format).
- Read toggle bit (`b1` bit 3); if equal to `rc5_last_tog` → ignore
  (auto-repeat from holding the button).
- Else save toggle, store `b0` in `rc5_cmd`, set `rc5_new = 1`.
- Clear `EIFR` (edges that fired during decode).
- reti.
- **Calls:** none (writes shared state for `dispatch` to pick up).

---

# EEPROM history module (eeprom.asm)

## `history_init`
- **In:** (none, called once from `reset`)
- Read magic at EEPROM `0x00`.
- If `!= 0xA5` (first boot):
  - Write min = `+125 °C` raw (`0x07D0`).
  - Write max = `−55 °C`  raw (`0xFC90`).
  - Write magic = `0xA5` **last** (crash mid-init → restart clean).
- Load min/max from EEPROM → SRAM mirror (`min_temp`, `max_temp`).
- **Calls:** `eeprom_read_byte`, `eeprom_write_byte`.

## `history_update`
- **In:** `a1:a0` = current temperature
- If `a1:a0 < min_temp` → update SRAM + EEPROM (LSB then MSB).
- If `a1:a0 > max_temp` → update SRAM + EEPROM.
- Preserves `a0`, `a1`.
- **Calls:** `eeprom_write_byte`.

## `eeprom_read_byte`
- **In:** `ZL` = EEPROM address (`ZH = 0`)
- **Out:** `w` = byte read
- Wait `EEWE`, set address, pulse `EERE`, read `EEDR`.

## `eeprom_write_byte`
- **In:** `ZL` = address, `w` = value
- Wait `EEWE`, set address + data.
- Save SREG, `cli`, `EEMWE` → `EEWE` within 4 cycles, restore SREG.
- (Safe to call from inside an ISR — that's why it saves SREG instead of doing
  a blind `sei`.)

---

# Servo module (servo.asm) — stubs

## `open_window`
- `window_open = 1`, `lcd_dirty = 1`.
- (TODO R: emit ~2 ms PWM pulse on PB4.)
- Called from `overflow0` (threshold), `do_normal` (manual VOL+).

## `close_window`
- `window_open = 0`, `lcd_dirty = 1`.
- (TODO R: emit ~1 ms PWM pulse on PB4.)
- Called from `overflow0` (threshold), `do_normal` (manual VOL−),
  `to_sleep` (forced shut).

---

# Suggested diagram layout (top-level)

Mirror the example image with **four lanes** and one shared-state box:

```
┌─────────────┐  ┌──────────────────┐  ┌────────────────┐  ┌──────────────┐
│   BOOT      │  │   MAIN LOOP      │  │  TIMER0 ISR    │  │  INT7 ISR    │
│   reset     │  │   main           │  │  overflow0     │  │  rc5_isr     │
│   ↓         │  │   ↓              │  │   ↓            │  │   ↓          │
│  history_   │  │  dispatch        │  │  history_      │  │ writes       │
│   init      │  │   ├ do_normal    │  │   update       │  │ rc5_cmd,     │
│  do_splash  │  │   ├ do_set       │  │  open_window   │  │ rc5_new      │
│             │  │   ├ do_sleep     │  │  close_window  │  │              │
│             │  │   └ do_history   │  │                │  │              │
│             │  │   ↓              │  │                │  │              │
│             │  │  lcd_refresh     │  │                │  │              │
│             │  │   ├ show_normal  │  │                │  │              │
│             │  │   ├ show_set     │  │                │  │              │
│             │  │   ├ show_sleep   │  │                │  │              │
│             │  │   └ show_history │  │                │  │              │
└─────────────┘  └──────────────────┘  └────────────────┘  └──────────────┘
                          ↕                    ↕                  ↕
                  ┌───────────────────────────────────────────────────┐
                  │  SHARED SRAM STATE                                │
                  │  mode_var, target_temp, window_open,              │
                  │  rc5_cmd, rc5_new, rc5_last_tog,                  │
                  │  lcd_dirty, min_temp, max_temp                    │
                  └───────────────────────────────────────────────────┘
```

The ISRs and the main loop never call each other directly — they all read/write
the shared SRAM box. That's the cleanest way to show the architecture.
