; file ir_sniff.asm   target ATmega128L-4MHz-STK300
; purpose hardware diagnostic for M2 module on PORTE
;         - buzzer (PE2) clicks every 500ms       ? confirms M2 has power
;         - LCD shows "WAITING..." then "GOT SIGNAL!"
;         - STK-300 LEDs (PORTB) toggle on every IR falling edge

.include "macros.asm"
.include "definitions.asm"

reset:
	LDSP		RAMEND			; stack pointer
	WAIT_MS		50				; LCD warmup
	rcall		LCD_init
	
	; --- I/O configuration ---
	sbi			DDRE, 2			; PE2 buzzer = output
	cbi			DDRE, 7			; PE7 IR input
	cbi			PORTE, 7		; pull-up off on PE7
	
	ldi			w, 0xff
	out			DDRB, w			; PORTB all output (STK-300 LEDs)
	ldi			w, 0xff
	out			PORTB, w		; LEDs off (active low on STK-300)
	
	rjmp		main

.include "lcd.asm"
.include "printf.asm"

; --- counter for buzzer timing ---
; We use r20 as a heartbeat counter to click the buzzer
; every N sniff iterations (since we can't WAIT_MS in the
; sniff loop — that would miss IR edges)

main:
	rcall		LCD_home
	PRINTF		LCD
.db	"WAITING...     ",0
	
	ldi			r20, 0			; heartbeat counter

sniff:
	; --- heartbeat: click buzzer every ~65000 iterations ---
	inc			r20
	brne		check_ir		; only click when r20 wraps to 0
	
	; toggle buzzer
	sbic		PORTE, 2
	rjmp		buzz_off
	sbi			PORTE, 2		; turn on
	rjmp		check_ir
buzz_off:
	cbi			PORTE, 2		; turn off

check_ir:
	sbic		PINE, 7			; skip if PE7 == 0 (IR detected)
	rjmp		sniff			; PE7 high ? keep waiting
	
	; --- IR signal detected ---
	
	; toggle LEDs (XOR PORTB with 0xff)
	in			w, PORTB
	com			w
	out			PORTB, w
	
	; show on LCD
	rcall		LCD_home
	PRINTF		LCD
.db	"GOT SIGNAL!    ",0
	
	; click buzzer hard
	sbi			PORTE, 2
	WAIT_MS		100
	cbi			PORTE, 2
	
	WAIT_MS		400				; hold display
	rjmp		main