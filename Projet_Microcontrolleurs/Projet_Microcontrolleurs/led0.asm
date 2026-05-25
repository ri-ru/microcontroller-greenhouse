; file	led0.asm   target ATmega128L-4MHz-STK300
; purpose measurements of frequencies
; out: PORTC pin 0: blinks at (1/8 x MCU real frequency)

.include "macros.asm"		; include macro definitions
.include "definitions.asm"	; include register/constant definitions

reset:	OUTI	DDRC,0xff	; make portB output

main:	

	inc	a0			; 1 cycle
	out	PORTC,a0	; 1 cycle
	rjmp	main	; 2 cylces	total: 4 cylces