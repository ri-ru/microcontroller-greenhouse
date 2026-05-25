; file ir_rc5.asm   target ATmega128L-4MHz-STK300
; purpose decodeur RC5, declenche par INT7 sur front descendant de PE7
;         depose la commande dans rc5_cmd et leve rc5_new

; T1 = duree d'un bit RC5 (1778 us standard, ajuste pour notre paire MCU/telecommande)
.equ T1 = 1870

rc5_isr:
	in	_sreg, SREG		; sauvegarde flags
	push	w
	push	u
	push	b0
	push	b1
	push	b2

	CLR2	b1, b0			; trame sur 14 bits (loges dans b1:b0)
	ldi	b2, 14			; compteur de bits
	WAIT_US	(T1/4)			; attendre 1/4 periode (echantillonnage au milieu du bit)

rc5_loop:
	P2C	PINE, IR		; lire pin IR -> carry
	ROL2	b1, b0			; carry -> registre 2 octets
	WAIT_US	(T1-4)			; attendre fin du bit (compensation 4 cycles)
	DJNZ	b2, rc5_loop

	com	b0			; format inverse (RC5)
	sts	rc5_cmd, b0
	STI	rc5_new, 1

	OUTI	EIFR, (1<<INTF7)	; effacer flag INT7 declenche par les fronts pendant le decodage

	pop	b2
	pop	b1
	pop	b0
	pop	u
	pop	w
	out	SREG, _sreg
	reti
