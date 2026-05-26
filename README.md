# Mini-serre

Greenhouse controller for the ATmega128L on an STK-300 board. Final project for the microcontrollers course, 2026.

Authors: Veronika Wannack, Raphaëlle Wohrer (group G118).

## What it does

A DS18B20 measures the temperature inside the greenhouse. If it rises above a set point, a servo opens a window; once it drops back, the servo closes it. You control everything with a Vivanco UR Z2 IR remote (RC5 protocol). A 2×16 LCD shows the current state. The min and max temperatures seen so far are kept in EEPROM so they survive a power cycle.

There are four modes:

- **NORMAL** — regulation runs, set point is held.
- **SET** — adjust the set point with CH+ / CH-.
- **SLEEP** — regulation paused, window forced closed, screen blanked.
- **HISTORY** — shows min/max read from EEPROM.

Mode transitions are driven entirely by the remote. `POWER` toggles SLEEP, `AV` toggles SET, `GUIDE` toggles HISTORY.

## How it's wired

| Peripheral | Port / Pin | Notes |
|---|---|---|
| DS18B20 (1-Wire) | `PORTB.5` (DQ) | external pull-up |
| Servo (Futaba S3003) | `PORTF.4` (SERVO1) | PWM generated in the main loop |
| IR receiver | `PORTE.7` (INT7) | falling edge starts RC5 decode |
| LCD 2×16 | external SRAM bus | written via the `PRINTF LCD` macro |
| Timer0 | async 32 kHz crystal | overflow ≈ 1 Hz, triggers a temp read |

## Source layout

```
Projet_Microcontrolleurs/Projet_Microcontrolleurs/
├── main.asm        # vector table, reset, state machine, main loop, mode dispatch
├── thermo.asm      # readT — DS18B20 read + threshold compare + window decision
├── servo.asm       # open_window / close_window (PWM itself lives in main.asm)
├── display.asm     # lcd_refresh — redraws line 1 when lcd_dirty is set; splash
├── eeprom.asm      # min/max history, persisted in internal EEPROM
├── ir_rc5.asm      # RC5 decoder ISR on INT7
├── wire1.asm       # Dallas 1-Wire library (provided by the course)
├── lcd.asm         # LCD init / primitives (course library)
├── printf.asm      # PRINTF macro support (course library)
├── macros.asm      # general macros (course library)
└── definitions.asm # register aliases, board pin map (course library)
```

`wire1.asm`, `lcd.asm`, `printf.asm`, `macros.asm`, and `definitions.asm` are the course-provided libraries; the rest is ours.

## How the loop works

The PWM for the servo is generated in `main`, TP10-style:

1. drop `SERVO1` low for ~18 ms (the gap between pulses)
2. during that gap, run `dispatch` (handle any new RC5 command) and, if Timer0 set the flag, run `readT`
3. raise `SERVO1` high for 1.52 ms (closed) or 1.90 ms (open)
4. drop it low again, loop

Temperature work is deferred out of the Timer0 ISR — the ISR only sets `convertT_ended = 1`, the main loop does the actual 1-Wire transactions. This keeps the ISR short enough that the servo pulse width stays clean and the IR decoder doesn't miss bits.

## State, in SRAM

Everything the state machine cares about sits in a small block at `0x0260`:

| Address | Name | Purpose |
|---|---|---|
| `0x0260` | `mode_var` | NORMAL / SET / SLEEP / HISTORY |
| `0x0261` | `target_temp` | set point, °C |
| `0x0262` | `window_open` | 0 = closed, 1 = open |
| `0x0263` | `rc5_cmd` | last command from the remote |
| `0x0264` | `rc5_new` | 1 = command waiting to be handled |
| `0x0265` | `rc5_last_tog` | RC5 toggle bit (filters auto-repeat) |
| `0x0266` | `lcd_dirty` | 1 = line 1 needs redrawing |
| `0x0267` | `min_temp` | SRAM mirror of EEPROM min (16-bit signed) |
| `0x0269` | `max_temp` | SRAM mirror of EEPROM max |
| `0x026b` | `convertT_ended` | Timer0 → main loop signal |

## EEPROM layout

5 bytes, starting at address 0:

```
0x00  magic byte (0xA5 = data valid, 0xFF = first boot)
0x01  min low
0x02  min high
0x03  max low
0x04  max high
```

On first boot the magic is unset, so `history_init` seeds min with +125 °C and max with -55 °C (the DS18B20 endpoints) — the first real reading will beat both. After that, every reading goes through `history_update`, which only writes when a new extreme appears.

## Remote codes (Vivanco UR Z2)

| Button | RC5 code | Used for |
|---|---|---|
| POWER | `0x0c` | toggle SLEEP |
| AV | `0x38` | toggle SET |
| GUIDE | `0x22` | toggle HISTORY |
| CH+ | `0x20` | UP (in SET) |
| CH- | `0x21` | DOWN (in SET) |

The set point is clamped between 5 °C and 40 °C.

## Building

Open `Projet_Microcontrolleurs/Projet_Microcontrolleurs.asmproj` in Microchip Studio (Atmel Studio 7), build, and program an STK-300 with an ATmega128L at 4 MHz.

## Report

`MCU2026-G118.tex` — the written report (in French) submitted with the project.
