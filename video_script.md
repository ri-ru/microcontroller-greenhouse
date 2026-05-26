# Demo video script — Smart greenhouse controller

**Target length: ~3 minutes (max imposed by the guidelines, section 2.4.3).**
**Speak calmly. One single take, no editing needed.**

---

## [0:00 – 0:15] Introduction

*(camera on the STK-300 board)*

> "Hello, we are Veronika and Raphaëlle, group G[XXX]. Our project is a
> **smart greenhouse controller** built around the ATmega128L on the
> STK-300 kit. The system measures the temperature, displays it on the
> LCD, automatically opens or closes a window via a servomotor based on
> a setpoint, and remembers the extreme temperatures even after a
> power outage."

*(point at each peripheral while naming it)*

> "Four peripherals: **Vivanco RC5 remote** (the mandatory peripheral),
> **2×16 LCD**, **DS18B20 1-wire temperature sensor**, and **Futaba
> S3003 servomotor**. Four modes: NORMAL, SET, SLEEP, and HISTORY."

---

## [0:15 – 0:55] NORMAL mode demo

*(power on the board — wait for the "Hello gardener!" splash, 2 s)*

> "On power-up, a splash screen shows for 2 seconds, then the system
> enters **NORMAL mode**. Line 1 shows the current state —
> `Set:25C. Closed.` — and line 2 refreshes every second with the
> measured temperature, here `Temp: 23.50 C`."

*(warm the sensor with a finger)*

> "If I warm the sensor above the setpoint, the controller detects the
> threshold crossing and the servomotor opens the window automatically.
> The display switches to `Open`. As soon as the temperature drops back
> down, the window closes again automatically."

*(press VOL+)*

> "I can also force it manually: **VOL+** opens, **VOL-** closes."

---

## [0:55 – 1:25] SET mode demo

*(press AV)*

> "**AV** enters **SET mode**: the display shows `<EDIT>`."

*(press CH+ a few times)*

> "**CH+** raises the setpoint, **CH-** lowers it. Clamped between
> 5 and 40 degrees."

*(press AV again)*

> "Pressing AV again returns to NORMAL with the new setpoint active
> immediately — on every Timer0 tick, the regulation routine re-reads
> the setpoint from SRAM."

---

## [1:25 – 1:50] SLEEP mode demo

*(press POWER)*

> "**POWER** enters **SLEEP mode**. The window is forced closed, the
> screen shows `Sleeping...` for 2 seconds, then the LCD is cleared.
> The Timer0 ISR still raises its flag, but `readT` detects SLEEP mode
> and exits immediately: no reading, no display update."

*(press POWER again)*

> "Pressing POWER again replays the splash screen, then returns to
> NORMAL with regulation resumed."

---

## [1:50 – 2:20] HISTORY mode demo

*(press GUIDE)*

> "**GUIDE** enters **HISTORY mode**: line 1 shows the minimum
> temperature ever measured, line 2 shows the maximum. These values
> are stored in the ATmega128's **internal EEPROM**, so they **survive
> a power outage**. On boot we just re-read the EEPROM; during normal
> operation, we only write back when a new extreme is crossed —
> typically a few times per day, well below the 100,000 write cycles
> guaranteed by the part."

*(press GUIDE again)*

> "Pressing GUIDE again returns to NORMAL."

---

## [2:20 – 3:00] Technical points

> "On the software side, the system is a **four-state state machine**
> driven by **two interrupts**:
>
> - **INT7** on falling edge decodes the RC5 protocol bit by bit, with
>   a toggle-bit filter to ignore the remote's auto-repeat.
> - **Timer0** in asynchronous mode on the 32 kHz watch crystal
>   overflows once per second.
>
> One important architectural point: the Timer0 ISR only **raises a
> flag** `convertT_ended`. The real work — DS18B20 read, EEPROM history
> update, regulation — runs in the `readT` routine called from the main
> loop. This prevents the ~20 ms servo PWM generation from masking
> INT7 and dropping RC5 frames.
>
> The **servo** is driven by software PWM directly in the main loop,
> TP10-style: 18 ms of pin low, then the work, then 1.5 or 1.9 ms of
> pin high depending on the target position. The servo sees roughly
> 50 Hz and holds its position.
>
> **Advanced concepts in use**: EEPROM for persistence of the
> extremes, 1-wire for the DS18B20, software PWM for the servo,
> multiple ISRs, and SRAM flags to decouple ISRs from the main loop.
>
> Thank you for your attention."

---

## Filming tips

- **Keep the remote in hand from the start** — don't fumble for it
  mid-take.
- **Run the scenario twice** before filming — especially the threshold
  crossing (warming / cooling the sensor). Have a small cup of lukewarm
  water ready if a finger isn't enough.
- **Check that an extreme is already in EEPROM before the HISTORY
  demo** — otherwise the displayed values will be the initial bounds
  (+125 / -55). A short warm-up and cool-down before the take is
  enough.
- **Frame the LCD steadily** during transitions so the grader can read
  it.
- **Don't read the script word-for-word** — it sounds robotic. Rehearse
  2–3 times so you can paraphrase naturally.
- **A single continuous take** is fine (editing is not required by the
  guidelines).
- **If you stumble, keep going** — natural beats perfect. Only redo if
  the demo itself fails.
