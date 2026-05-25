; file ir_sniff.asm   target ATmega128L-4MHz-STK300
; purpose detect any IR activity on PORTE bit 7 (M2 module)
;         displays "GOT SIGNAL!" when PE7 goes low

.include "macros.asm"
.include "definitions.asm"

reset:
	LDSP		RAMEND			; set stack pointer
	WAIT_MS		50				; LCD warmup delay
	rcall		LCD_init		; initialize LCD
	
	; force PORTE bit 7 as input, no pull-up
	cbi			DDRE, 7			; DDRE bit 7 = 0 (input)
	cbi			PORTE, 7		; PORTE bit 7 = 0 (pull-up off)
	
	rjmp		main

.include "lcd.asm"
.include "printf.asm"

main:
	rcall		LCD_home
	PRINTF		LCD
.db	"waiting...     ",0			; 15 chars to overwrite previous text

sniff:
	sbic		PINE, 7			; skip next if PE7 == 0
	rjmp		sniff			; PE7 high ? keep waiting
	
	; PE7 went low ? IR signal detected
	rcall		LCD_home
	PRINTF		LCD
.db	"GOT SIGNAL!    ",0
	
	WAIT_MS		800				; hold display for 0.8 sec
	rjmp		main