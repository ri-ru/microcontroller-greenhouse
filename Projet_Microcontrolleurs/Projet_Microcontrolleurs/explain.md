; ==============================================================
;  explain.md  --  walkthrough of main.asm for a beginner
;  target ATmega128L-4MHz, STK-300 board
;
;  Read this top-to-bottom. Every block of code from main.asm is
;  repeated here with very extensive comments. The diagrams use
;  ASCII art so they render fine in any editor.
; ==============================================================


; ==============================================================
;  PART 0  --  THE BIG PICTURE
; ==============================================================
;
;  The program is a greenhouse controller. It has THREE things
;  happening "at the same time" :
;
;     1. The MAIN LOOP : reads the current mode, reacts to button
;        presses, refreshes the LCD. Runs forever.
;
;     2. The IR INTERRUPT (INT7) : every time the remote control
;        sends a button code, the IR receiver pulls the PE7 pin
;        low. The CPU drops what it is doing, jumps to rc5_isr,
;        decodes the code, stores it in SRAM, then returns.
;
;     3. The TIMER0 INTERRUPT (every ~1 second) : reads the
;        DS18B20 temperature sensor, prints the value on line 1
;        of the LCD, and opens/closes the window depending on
;        whether the measured temperature is above or below the
;        target.
;
;  The three parts do NOT call each other directly. They
;  communicate through SRAM "mailboxes" :
;
;       +---------+        SRAM        +-----------+
;       |  IR     | -- writes rc5_cmd -|           |
;       |  ISR    | -- raises rc5_new->|           |
;       +---------+                    |           |
;                                      |  shared   |
;       +---------+                    |  state    |
;       | Timer0  | -- reads mode_var-->           |
;       |  ISR    | <-- reads target_temp         |
;       |         | -- writes window_open->       |
;       +---------+                    |           |
;                                      |           |
;       +---------+                    |           |
;       |  main   | <-- reads rc5_new -|           |
;       |  loop   | -- writes mode_var->          |
;       |         | -- raises lcd_dirty->         |
;       +---------+                    +-----------+
;
;  This is the whole architecture in one picture.


; ==============================================================
;  PART 1  --  STATE MACHINE
; ==============================================================
;
;  The greenhouse is always in exactly ONE of these three modes :
;
;
;                     +-----------+
;             SET     |           |    POWER
;       +-------------+  NORMAL   +-------------+
;       |             |           |             |
;       |             +---+---+---+             |
;       |                 ^   ^                 |
;       |                 |   |                 v
;       v                 |   |             +-------+
;   +-------+   SET       |   |   POWER     |       |
;   |       +-------------+   +-------------+ SLEEP |
;   |  SET  |                                |       |
;   |       +<-------------------------------+       |
;   +---+---+         POWER (from SET)       +-------+
;       |
;       |  CH+   -> target_temp + 1   (max 40 degC)
;       |  CH-   -> target_temp - 1   (min  5 degC)
;       +--
;
;       (NORMAL extras :  VOL+ opens window, VOL- closes window)
;       (SLEEP : window forced closed, only POWER wakes up)
;
;  Buttons that have NO effect in a given mode are simply
;  ignored.


; ==============================================================
;  PART 2  --  SRAM MAP
; ==============================================================
;
;  We use a small region of SRAM as our "global variables".
;  Each variable is ONE byte. Addresses are chosen in the range
;  0x0260..0x02ff because printf.asm requires it.
;
;        addr     name             meaning
;        ----     ----             -------
;        0x0260   mode_var         0=NORMAL, 1=SET, 2=SLEEP
;        0x0261   target_temp      target temperature in degC
;        0x0262   window_open      0=closed, 1=open
;        0x0263   rc5_cmd          last RC5 button code received
;        0x0264   rc5_new          1 = a fresh button is waiting
;        0x0265   rc5_last_tog     RC5 toggle bit filter
;        0x0266   lcd_dirty        1 = line 2 of LCD must be redrawn


; ==============================================================
;  PART 3  --  THE FILE, LINE BY LINE
; ==============================================================


; --------------------------------------------------------------
;  Header and includes
; --------------------------------------------------------------

    ; file	main.asm   target ATmega128L-4MHz-STK300
    ; purpose serre: state-machine (NORMAL / SET / SLEEP), LCD, RC5 ISR

    .include "macros.asm"        ; gives us STI, OUTI, _JK, CA, LDSP, PRINTF, ...
    .include "definitions.asm"   ; gives us register names : w, a0..a3, b0..b3, ...

    ; ".include" is just "copy-paste this file here at assembly time".
    ; It is NOT a runtime call. After assembly, everything lives in
    ; one big flat program.


; --------------------------------------------------------------
;  Named constants (.equ)
; --------------------------------------------------------------

    .equ  MODE_NORMAL = 0
    .equ  MODE_SET    = 1
    .equ  MODE_SLEEP  = 2

    ; ".equ NAME = number" is a compile-time alias. After this,
    ; writing MODE_NORMAL anywhere is exactly the same as writing 0.
    ; No memory is used. It's just a readable name.

    .equ  mode_var     = 0x0260   ; SRAM address of our mode byte
    .equ  target_temp  = 0x0261   ; SRAM address of the target temp
    .equ  window_open  = 0x0262
    .equ  rc5_cmd      = 0x0263
    .equ  rc5_new      = 0x0264
    .equ  rc5_last_tog = 0x0265
    .equ  lcd_dirty    = 0x0266

    ; These addresses do NOT magically reserve memory. They are just
    ; numbers. The convention is "we promise to use 0x0260 for the
    ; mode, 0x0261 for the target, ...". As long as nobody else in
    ; the program writes to those addresses, we are fine.

    .equ  KEY_SET   = 0x38   ; AV    -> enter/exit SET mode
    .equ  KEY_UP    = 0x20   ; CH+   -> target +1
    .equ  KEY_DOWN  = 0x21   ; CH-   -> target -1
    .equ  KEY_POWER = 0x0c   ; POWER -> toggle SLEEP
    .equ  KEY_OPEN  = 0x10   ; VOL+  -> open window
    .equ  KEY_CLOSE = 0x11   ; VOL-  -> close window

    ; These are the raw RC5 codes that the Vivanco UR Z2 remote
    ; sends when each button is pressed. We captured them on
    ; 2026-05-25 with a sniffer program.


; --------------------------------------------------------------
;  Interrupt vector table
; --------------------------------------------------------------
;
;  When the chip boots, the CPU starts executing instructions
;  from program address 0. When an interrupt fires, the CPU
;  jumps to a SPECIFIC, FIXED address depending on which
;  interrupt it was. Those addresses are called "vectors".
;
;  Layout in flash :
;
;       0x0000  reset vector       -> jmp reset
;       0x000X  INT0  vector
;       0x000Y  INT1  vector
;       ...
;       INT7addr                   -> rjmp rc5_isr
;       ...
;       OVF0addr                   -> rjmp overflow0
;
;  ".org N" tells the assembler "place the next instruction at
;  program address N". We only fill in the vectors we use; the
;  others stay empty (they would crash if they fired, but we
;  never enable them, so they cannot fire).

    .org  0
        jmp   reset            ; CPU starts here after power-on / reset

    .org  INT7addr
        rjmp  rc5_isr          ; IR receiver triggers this

    .org  OVF0addr
        rjmp  overflow0        ; Timer0 overflow triggers this


; --------------------------------------------------------------
;  Library includes (placed BEFORE reset on purpose)
; --------------------------------------------------------------
;
;  The order of .include matters here. reset itself uses PRINTF
;  and LCD_* (for the welcome screen), so those library symbols
;  MUST already be defined by the time the assembler reaches
;  reset. That's why we include the libraries first.

    .include "lcd.asm"      ; LCD_init, LCD_home, LCD_lf, LCD_clear, ...
    .include "printf.asm"   ; PRINTF macro + supporting subroutines
    .include "wire1.asm"    ; wire1_init, wire1_reset, wire1_read, wire1_write, ...
    .include "ir_rc5.asm"   ; the rc5_isr subroutine


; --------------------------------------------------------------
;  reset:  one-shot initialization, runs once at power-on
; --------------------------------------------------------------

reset:
    LDSP  RAMEND
    ; LDSP = "Load Stack Pointer". The stack lives in SRAM and
    ; grows DOWNWARD. We point it at the very top of RAM (RAMEND)
    ; so it has room to grow. Without this, any "rcall" or "push"
    ; would corrupt random memory.

    in    w, MCUCR
    sbr   w, (1<<SRE)+(1<<SRW10)
    out   MCUCR, w
    ; Three-step "set bits in a hardware register" :
    ;   in  w, MCUCR   -> copy MCUCR into register w
    ;   sbr w, ...     -> set bits SRE and SRW10 in w
    ;   out MCUCR, w   -> write w back
    ; SRE = enable external SRAM. The STK-300 board wires the LCD
    ; through the external SRAM bus, so the LCD will not work
    ; without this.

    cbi   DDRE,  IR        ; clear bit IR in DDRE  -> PE7 is an INPUT
    cbi   PORTE, IR        ; clear bit IR in PORTE -> no pull-up
    ; The IR receiver chip drives PE7 itself (active low). It has
    ; its own pull-up, so we disable the internal one.

    rcall wire1_init       ; init the 1-wire bus (DS18B20 sensor)
    rcall LCD_init         ; init the LCD controller

    ; --- welcome screen (3 seconds before normal display kicks in) ---
    rcall LCD_home
    PRINTF LCD
.db "Hello gardener!",0
    WAIT_MS 3000           ; busy-wait for 3000 ms (a TP macro)
    rcall LCD_clear        ; wipe the screen so it's clean for the real display
    ; Note : this WAIT_MS happens BEFORE we enable interrupts (sei
    ; is further down). That's deliberate -- it means the welcome
    ; screen stays put for the full 3 seconds, undisturbed by
    ; Timer0 overflows or IR button presses.

    ; --- initial state ---
    STI   mode_var,    MODE_NORMAL
    STI   target_temp, 25
    STI   window_open, 0
    STI   rc5_cmd,     0
    STI   rc5_new,     0
    STI   rc5_last_tog, 0xff   ; impossible toggle value -> first press always accepted
    STI   lcd_dirty,   1       ; force first LCD draw

    ; STI is a macro from macros.asm. "STI addr, value" expands to :
    ;     ldi w, value
    ;     sts addr, w
    ; i.e. "store this immediate value into that SRAM address".
    ; You will see STI everywhere in this file.

    ; --- INT7 setup (RC5 IR receiver) ---
    OUTEI EICRB, (1<<ISC71)    ; INT7 triggers on FALLING edge
    OUTI  EIFR,  (1<<INTF7)    ; clear any stale flag
    OUTI  EIMSK, (1<<INT7)     ; ENABLE INT7
    ; OUTI is "out immediate", same idea as STI but for I/O regs.

    ; --- Timer0 setup ---
    ;
    ;   Timer0 is run from the 32.768 kHz watch crystal (asynchronous).
    ;     32768 / 128 (prescaler) / 256 (8-bit overflow) = 1 Hz.
    ;   So overflow fires roughly ONCE PER SECOND.
    ;
    OUTI  TIMSK, (1<<TOIE0)    ; enable Timer0 overflow interrupt
    OUTI  ASSR,  (1<<AS0)      ; clock Timer0 from the external crystal
    OUTI  TCCR0, 5             ; prescaler = 128
    sei                        ; GLOBAL interrupt enable

    ; sei = "Set Interrupt flag". Until we call sei, ALL interrupts
    ; are blocked, no matter what EIMSK or TIMSK say.

    ; --- kick off the first DS18B20 conversion ---
    rcall wire1_reset
    CA    wire1_write, skipROM       ; "talk to the only sensor on the bus"
    CA    wire1_write, convertT      ; "start a temperature measurement"
    ; CA is "Call with Argument" : it does "ldi a0, arg ; rcall sub".
    ; The conversion takes ~750 ms; by the time Timer0 overflows
    ; (~1 s), the result is ready in the sensor's scratchpad.
    ;
    ; Note : we do NOT initialize b3:b2 here. The target temperature
    ; is reloaded from SRAM (target_temp) on every Timer0 tick, so
    ; that pressing CH+/CH- in SET mode actually changes the
    ; threshold used by the window control.

    rjmp  main                 ; jump to the main loop forever


; ==============================================================
;  MAIN LOOP
; ==============================================================
;
;  Picture of one iteration :
;
;       +---------------------+
;       |  dispatch           |  -- "what mode are we in?
;       |                     |      did the user press a key?
;       |                     |      if yes, act on it"
;       +----------+----------+
;                  |
;                  v
;       +---------------------+
;       |  lcd_refresh        |  -- "did anything change?
;       |                     |      if yes, repaint line 2"
;       +----------+----------+
;                  |
;                  v
;       +---------------------+
;       |  rjmp main          |  -- start over forever
;       +---------------------+
;
;  The loop is purely reactive. It does NOT poll the IR pin and
;  it does NOT read the temperature. Both are handled by their
;  ISRs in the background, which drop their results in SRAM.

main:
    rcall dispatch
    rcall lcd_refresh
    rjmp  main


; --------------------------------------------------------------
;  dispatch : look at mode_var, jump to the right handler
; --------------------------------------------------------------

dispatch:
    lds   w, mode_var
    ; lds = "Load from SRAM". w now holds 0, 1 or 2.

    _JK   w, MODE_NORMAL, do_normal
    _JK   w, MODE_SET,    do_set
    _JK   w, MODE_SLEEP,  do_sleep
    ret
    ; _JK is "Jump if eKual" : "_JK reg, value, label" =
    ;   cpi reg, value
    ;   breq label
    ; So this whole block reads like a switch/case :
    ;     switch (mode) {
    ;       case NORMAL: goto do_normal;
    ;       case SET:    goto do_set;
    ;       case SLEEP:  goto do_sleep;
    ;     }


; --------------------------------------------------------------
;  do_normal : handler for NORMAL mode
; --------------------------------------------------------------

do_normal:
    lds   w, rc5_new            ; was a new IR button received ?
    tst   w                     ; tst = "test for zero"
    breq  dn_end                ; if 0, nothing to do -> return
    lds   a0, rc5_cmd           ; load the button code
    STI   rc5_new, 0            ; consume the flag (back to 0)

    ; Now react. Each _JK is "if a0 equals this key, goto that handler".
    ; Note that the handler RETs from there, so the order is "first
    ; match wins". Any other key is silently ignored.

    _JK   a0, KEY_SET,   to_set
    _JK   a0, KEY_POWER, to_sleep
    _JK   a0, KEY_OPEN,  open_window
    _JK   a0, KEY_CLOSE, close_window
dn_end:
    ret


; --------------------------------------------------------------
;  do_set : handler for SET mode (adjust target temperature)
; --------------------------------------------------------------

do_set:
    lds   w, rc5_new
    tst   w
    breq  ds_end
    lds   a0, rc5_cmd
    STI   rc5_new, 0
    _JK   a0, KEY_SET,   to_normal       ; AV again -> back to NORMAL
    _JK   a0, KEY_POWER, to_sleep        ; POWER even in SET -> SLEEP
    _JK   a0, KEY_UP,    target_up       ; CH+ -> target + 1
    _JK   a0, KEY_DOWN,  target_down     ; CH- -> target - 1
ds_end:
    ret


; --------------------------------------------------------------
;  do_sleep : handler for SLEEP mode (only POWER does anything)
; --------------------------------------------------------------

do_sleep:
    lds   w, rc5_new
    tst   w
    breq  dz_end
    lds   a0, rc5_cmd
    STI   rc5_new, 0
    _JK   a0, KEY_POWER, to_normal
dz_end:
    ret


; --------------------------------------------------------------
;  Mode transitions  --  three tiny subroutines that set mode_var
;                        and mark the LCD as needing a redraw
; --------------------------------------------------------------

to_normal:
    STI   mode_var, MODE_NORMAL
    STI   lcd_dirty, 1
    ret

to_set:
    STI   mode_var, MODE_SET
    STI   lcd_dirty, 1
    ret

to_sleep:
    STI   mode_var, MODE_SLEEP
    rjmp  close_window
    ; Note : we fall through into close_window via rjmp, which
    ; itself sets lcd_dirty and rets. So we get "close the window
    ; AND mark LCD dirty AND return" in one step.


; --------------------------------------------------------------
;  target_up / target_down : adjust target_temp with clamping
; --------------------------------------------------------------

target_up:
    lds   w, target_temp
    cpi   w, 40              ; already at 40 ?
    brsh  tu_end             ; brsh = "Branch if Same or Higher" (unsigned)
    inc   w                  ; w = w + 1
    sts   target_temp, w
    STI   lcd_dirty, 1
tu_end:
    ret

target_down:
    lds   w, target_temp
    cpi   w, 5               ; already below 5 ?
    brlo  td_end             ; brlo = "Branch if LOwer" (unsigned)
    dec   w
    sts   target_temp, w
    STI   lcd_dirty, 1
td_end:
    ret


; --------------------------------------------------------------
;  Window control  --  for now just toggles the SRAM flag
;                      (R will replace these with servo commands)
; --------------------------------------------------------------

open_window:
    STI   window_open, 1
    STI   lcd_dirty, 1
    ret

close_window:
    STI   window_open, 0
    STI   lcd_dirty, 1
    ret


; ==============================================================
;  TIMER0 OVERFLOW ISR  --  fires roughly once per second
; --------------------------------------------------------------
;
;  Flow of one ISR call :
;
;       +-----------------------------------+
;       |  save SREG + every register we    |
;       |  are about to clobber             |
;       +-----------------------------------+
;                       |
;                       v
;       +-----------------------------------+
;       |  read DS18B20 scratchpad          |
;       |     wire1_reset                   |
;       |     skipROM                       |
;       |     readScratchpad                |
;       |     read LSB -> a0                |
;       |     read MSB -> a1                |
;       |  -> a1:a0 = temperature           |
;       +----------------+------------------+
;                        |
;                        v
;       +-----------------------------------+
;       |  print "temp=XX.YY C" on LCD      |
;       |  line 1                           |
;       +----------------+------------------+
;                        |
;                        v
;       +-----------------------------------+
;       |  kick off next conversion         |
;       |     wire1_reset / skipROM /       |
;       |     convertT                      |
;       +----------------+------------------+
;                        |
;                        v
;             +----------+----------+
;             | mode == SLEEP ?     |
;             +-----+----------+----+
;            yes    |          | no
;                   v          v
;            +---------+   +------------------+
;            | skip    |   | temp - target    |
;            | window  |   | >= 0 -> open      |
;            | control |   | <  0 -> close     |
;            +----+----+   +---------+--------+
;                 |                  |
;                 +--------+---------+
;                          v
;       +-----------------------------------+
;       |  restore all registers, SREG      |
;       |  reti                             |
;       +-----------------------------------+
;
;  Why all the push/pop?
;    The main loop is using these registers. The ISR will overwrite
;    them. If we don't save and restore, the main loop will resume
;    with garbage values and break.
; ==============================================================

overflow0:
    in    _sreg, SREG          ; save the status register first
    push  w
    push  u
    push  char                 ; r0  (used by PRINTF)
    push  e0                   ; r4  (used by PRINTF)
    push  e1                   ; r5  (used by PRINTF)
    push  c0                   ; r8  (we use it to swap LSB)
    push  a0
    push  a1
    push  a2
    push  a3
    push  b0
    push  b1
    push  b2                   ; b2/b3 are clobbered by the reload-target block below
    push  b3
    push  xl
    push  xh
    push  yl
    push  yh
    push  zl
    push  zh

    ; --- read temperature from DS18B20, display on LCD line 1 ---
    rcall LCD_home                  ; move LCD cursor to row 1, col 1
    rcall wire1_reset
    CA    wire1_write, skipROM
    CA    wire1_write, readScratchpad
    rcall wire1_read                ; first byte = LSB -> arrives in a0
    mov   c0, a0                    ; stash LSB in c0
    rcall wire1_read                ; second byte = MSB -> a0
    mov   a1, a0                    ; a1 = MSB
    mov   a0, c0                    ; a0 = LSB ; now a1:a0 = full 16-bit value

    ; PRINTF/FFRAC2 internally chews up a0..a3 while it formats the
    ; number into digits. After PRINTF returns, the temperature is
    ; gone from a1:a0. We still need it for the comparison below,
    ; so we push it on the stack and pop it back after.
    push  a0
    push  a1
    PRINTF LCD
.db "Temp: ",FFRAC2+FSIGN,a,4,$22," C  ",CR,0
    ; printf format reads :
    ;   "Temp: "               : literal text
    ;   FFRAC2+FSIGN, a, 4, $22 : print register pair a (a1:a0) as a
    ;                            signed fractional, 4 digits, 2 decimals,
    ;                            with a format/scale byte ($22) that
    ;                            tells the library how the value is scaled
    ;   " C  "                 : literal text
    ;   CR, 0                  : carriage return + end marker

    rcall wire1_reset               ; kick off the NEXT conversion now,
    CA    wire1_write, skipROM      ; so it is ready ~1 s from now
    CA    wire1_write, convertT
    pop   a1                        ; restore the temperature we saved
    pop   a0                        ; (pop in reverse order!)

    ; --- window control by threshold (skip when in SLEEP) ---
    lds   w, mode_var
    cpi   w, MODE_SLEEP
    breq  ov_done                   ; if SLEEP, do nothing more

    ; --- reload the target from SRAM each tick ---
    ; The sensor returns values in 1/16 degC, so we need to convert
    ; target_temp (in plain degC) to the same scale : multiply by 16.
    ; Multiplying by 16 is the same as shifting left 4 times.
    lds   w, target_temp
    ldi   b3, 0
    mov   b2, w                     ; b3:b2 = 0x00:target_temp
    lsl   b2                        ; lsl = "Logical Shift Left" : b2 << 1, low bit becomes 0,
    rol   b3                        ; rol = "Rotate Left through carry" : b3 << 1, carry from b2 enters low bit
    lsl   b2                        ; doing lsl/rol as a pair shifts the 16-bit number b3:b2 left by 1
    rol   b3
    lsl   b2                        ; after 4 pairs : b3:b2 = target_temp << 4 = target_temp * 16
    rol   b3
    lsl   b2
    rol   b3                        ; b3:b2 now holds the target in DS18B20 format

    ; compute (a1:a0) - (b3:b2)   -- 16-bit subtract
    mov   b0, a0
    mov   b1, a1
    sub   b0, b2                    ; LSB subtract
    sbc   b1, b3                    ; MSB subtract with borrow
    brmi  ov_close                  ; if result is negative -> temp < target

    ; temp >= target : open the window (only if not already open)
    lds   w, window_open
    tst   w
    brne  ov_done                   ; already open -> do nothing
    rcall open_window
    rjmp  ov_done

ov_close:
    ; temp < target : close the window (only if not already closed)
    lds   w, window_open
    tst   w
    breq  ov_done                   ; already closed -> do nothing
    rcall close_window

ov_done:
    ; pop in REVERSE order from the pushes
    pop   zh
    pop   zl
    pop   yh
    pop   yl
    pop   xh
    pop   xl
    pop   b3
    pop   b2
    pop   b1
    pop   b0
    pop   a3
    pop   a2
    pop   a1
    pop   a0
    pop   c0
    pop   e1
    pop   e0
    pop   char
    pop   u
    pop   w
    out   SREG, _sreg               ; restore status register
    reti                            ; "Return from Interrupt" (also re-enables interrupts)


; ==============================================================
;  LCD REFRESH  --  redraw line 2 only when something changed
; --------------------------------------------------------------
;
;  LCD layout :
;
;       +------------------+
;       | temp=23.50 C     |   <-- line 1, written by overflow0 ISR
;       | set=25 win=0     |   <-- line 2, written here
;       +------------------+
;
;  We do NOT redraw line 2 every loop iteration. We only redraw
;  when lcd_dirty has been raised by some action (mode change,
;  target adjust, window toggle). This avoids the LCD flickering
;  and keeps the loop snappy.
; ==============================================================

lcd_refresh:
    lds   w, lcd_dirty
    tst   w
    breq  lr_skip                ; flag is 0 -> nothing to do
    STI   lcd_dirty, 0           ; consume the flag
    lds   w, mode_var
    _JK   w, MODE_NORMAL, show_normal
    _JK   w, MODE_SET,    show_set
    _JK   w, MODE_SLEEP,  show_sleep
lr_skip:
    ret

show_normal:
    rcall LCD_lf                 ; move cursor to line 2
    ; NORMAL mode shows the target AND a human-readable window state.
    ; We branch on window_open so the user reads "Open" / "Closed"
    ; instead of a cryptic "win=0".
    lds   w, window_open
    tst   w
    brne  show_normal_open       ; window open -> jump to the "Open" string
    PRINTF LCD
.db "Set:",FDEC|FDIG2,low(target_temp),"C. Closed.",0
    ret
show_normal_open:
    PRINTF LCD
.db "Set:",FDEC|FDIG2,low(target_temp),"C. Open.  ",0
    ; The trailing two spaces overwrite the "d." leftover from
    ; "Closed." -- the LCD never clears characters by itself, so
    ; if we don't pad, old text stays on screen.
    ret

show_set:
    rcall LCD_lf
    PRINTF LCD
.db "Set:",FDEC|FDIG2,low(target_temp),"C. <EDIT>.",0
    ; the "<EDIT>" tag tells the user that CH+/CH- now adjust
    ; the target.
    ret

show_sleep:
    rcall LCD_lf
    PRINTF LCD
.db "Sleeping...     ",0
    ret


; ==============================================================
;  THAT'S THE WHOLE FILE
; ==============================================================
;
;  Recap in 5 bullet points :
;
;   1. reset  : set up the stack, peripherals, default state,
;               first DS18B20 conversion, then jump to main.
;
;   2. main   : forever : dispatch -> lcd_refresh -> repeat.
;
;   3. The IR ISR (in ir_rc5.asm) decodes a button press into
;      rc5_cmd and raises rc5_new. The main loop checks the flag,
;      consumes it, and acts on the button based on the mode.
;
;   4. The Timer0 ISR fires ~1x per second, reads temperature,
;      prints it on LCD line 1, and decides whether to open or
;      close the window based on the target (skipped in SLEEP).
;
;   5. SRAM is the meeting point. ISRs and main loop never call
;      each other; they only read/write shared variables.
;
;  If you understand the diagram in PART 0 and the SRAM table in
;  PART 2, you understand the architecture. Everything else is
;  glue code following TP-style patterns.
