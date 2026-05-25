; file	wire1_temp2.asm		
; purpose Dallas 1-wire(R) temperature sensor interfacing: temperature
; module: M5, input port: PORTB
.include "macros.asm"		; include macro definitions
.include "definitions.asm"	; include register/constant definitions

; === interrupt vector table ===
.org	0
	jmp	reset
.org	OVF0addr ; timer overflow 0 interrupt vector
	rjmp	overflow0


.org	0x30
.include "lcd.asm"			; include LCD driver routines
.include "printf.asm"		; include formatted printing routines
.include "wire1.asm"		; include Dallas 1-wire(R) routines

; === interrupt service routines === 
overflow0:
	in _sreg, SREG
	rcall	lcd_home			; place cursor to home position
	rcall	wire1_reset			; send a reset pulse
	CA	wire1_write, skipROM
	CA	wire1_write, readScratchpad	
	rcall	wire1_read			; read temperature LSB
	mov	c0,a0
	rcall	wire1_read			; read temperature MSB
	mov	a1,a0
	mov	a0,c0
	PRINTF	LCD
.db	"temp=",FFRAC2+FSIGN,a,4,$42,"C ",CR,0
	rcall	wire1_reset			; send a reset pulse
	CA	wire1_write, skipROM	; skip ROM identification
	CA	wire1_write, convertT	; initiate temp conversion
	bst b1, 7 ; store information of the state of the window (1=closed 0=open)
	mov b0, a0
	mov b1, a1
	sub b0, b2
	sbc b1, b3
	brbc 6, PC+2 ; branch if T is clear <=> the window is already open
	brbc 2, PC+1 ; branch if N is clear <=> Temp > limit
	nop;rcall open_window
	brbs 6, PC+2 ; branch if T is set <=> the window is already closed
	brbs 2, PC+1 ; branch if N is set <=> Temp < limit
	nop;rcall open_window
	out SREG, _sreg
	reti



; === initialization (reset) ===
reset:		
	LDSP	RAMEND			; load stack pointer (SP)
	rcall	wire1_init		; initialize 1-wire(R) interface
	rcall	lcd_init		; initialize LCD
	OUTI	TIMSK,(1<<TOIE0)	; Timer0 Overflow Interrupt Enable
	OUTI	ASSR,(1<<AS0)
	OUTI	TCCR0,5
	sei				; set global interrupt
	ldi b2, 0b10010000
	ldi b3, 0b00000001 ; load 25 C as limit temperature
	rcall	wire1_reset			; send a reset pulse
	CA	wire1_write, skipROM	; skip ROM identification
	CA	wire1_write, convertT	; initiate temp conversion



; === main program ===
main:
	rjmp	main
