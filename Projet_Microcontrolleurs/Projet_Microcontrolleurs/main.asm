.include "m128def.inc"

.equ	LCD_IR	= 0x8000
.equ	LCD_DR	= 0xc000

.macro	LD_IR
a:	lds	r16,LCD_IR
	sbrc	r16,7
	rjmp	a
	ldi	r16,@0
	sts	LCD_IR,r16
	.endmacro

.macro	LD_DR
b:	lds	r16,LCD_IR
	sbrc	r16,7
	rjmp	b
	ldi	r16,@0
	sts	LCD_DR,r16          ; ? writes to DATA register
	.endmacro

reset:
	in	r16,MCUCR
	sbr	r16,(1<<SRE)+(1<<SRW10)
	out	MCUCR,r16

	; LCD power-on warmup delay (~50ms at 4 MHz)
	ldi	r17, 200
delay_outer:
	ldi	r18, 250
delay_inner:
	dec	r18
	brne	delay_inner
	dec	r17
	brne	delay_outer

main:
	; Function set: 8-bit, 2 lines, 5x8 font
	LD_IR	0b00111000
	LD_IR	0b00001111		; display on, cursor on, blink
	LD_IR	0b00000110		; entry mode: increment, no shift
	LD_IR	0b00000001		; clear display

	LD_DR	'H'
	LD_DR	'I'
	LD_DR	' '
	LD_DR	'!'
loop:
	rjmp	loop