; file	eeprom.asm   target ATmega128L-4MHz-STK300
; purpose driver EEPROM interne + historique min/max temperature.
;         Les extremes survivent au power-off (EEPROM = memoire non-volatile).
;
; EEPROM map (5 octets) :
;   0x00          magic (0xA5)         ; 0xFF = 1er boot, 0xA5 = donnees OK
;   0x01..0x02    min_temp (LSB, MSB)  ; format DS18B20 16-bit signe
;   0x03..0x04    max_temp (LSB, MSB)
;
; SRAM mirror (adresses .equ dans main.asm) :
;   min_temp (0x0267..0x0268), max_temp (0x0269..0x026A)
; -> lectures rapides depuis l'ISR Timer0, ecriture EEPROM seulement
;    quand un extreme change (rare).

.equ	EE_MAGIC	= 0x00
.equ	EE_MIN_LO	= 0x01
.equ	EE_MIN_HI	= 0x02
.equ	EE_MAX_LO	= 0x03
.equ	EE_MAX_HI	= 0x04
.equ	EE_MAGIC_OK	= 0xA5

; ==============================================================
;  eeprom_read_byte
;  in:  ZL = adresse EEPROM (ZH = 0)
;  out: w  = octet lu
; ==============================================================
eeprom_read_byte:
ee_rd_wait:
	sbic	EECR, EEWE		; attendre fin d'ecriture eventuelle
	rjmp	ee_rd_wait
	out	EEARH, ZH
	out	EEARL, ZL
	sbi	EECR, EERE		; declencher la lecture
	in	w, EEDR
	ret

; ==============================================================
;  eeprom_write_byte
;  in:  ZL = adresse, w = valeur
;  La sequence EEMWE -> EEWE doit tenir en 4 cycles : on coupe
;  les interruptions le temps de l'amorcage. On sauve SREG plutot
;  qu'un sei aveugle, parce que l'appelant peut deja etre dans une
;  ISR (history_update est appelle depuis overflow0).
; ==============================================================
eeprom_write_byte:
ee_wr_wait:
	sbic	EECR, EEWE		; attendre fin d'ecriture precedente
	rjmp	ee_wr_wait
	out	EEARH, ZH
	out	EEARL, ZL
	out	EEDR, w
	in	u, SREG			; sauvegarder l'etat des interruptions
	cli
	sbi	EECR, EEMWE		; master write enable
	sbi	EECR, EEWE		; lance l'ecriture (dans les 4 cycles)
	out	SREG, u			; restaurer (ne reactive que si I etait a 1)
	ret

; ==============================================================
;  history_init  (appelle dans reset)
;  - lit le magic en EEPROM 0x00
;  - si != 0xA5 : 1er boot, ecrire valeurs initiales et magic
;  - charger min/max EEPROM dans la SRAM mirror
; ==============================================================
history_init:
	ldi	ZH, 0			; adresses EEPROM tiennent dans ZL seul
	ldi	ZL, EE_MAGIC
	rcall	eeprom_read_byte
	cpi	w, EE_MAGIC_OK
	breq	hi_load			; donnees valides -> charger

	; 1er boot : initialiser EEPROM
	; min <- +125 degC (raw DS18B20 = 0x07D0, max possible)
	ldi	ZL, EE_MIN_LO
	ldi	w, 0xD0
	rcall	eeprom_write_byte
	ldi	ZL, EE_MIN_HI
	ldi	w, 0x07
	rcall	eeprom_write_byte
	; max <- -55 degC (raw DS18B20 = 0xFC90, min possible)
	ldi	ZL, EE_MAX_LO
	ldi	w, 0x90
	rcall	eeprom_write_byte
	ldi	ZL, EE_MAX_HI
	ldi	w, 0xFC
	rcall	eeprom_write_byte
	; magic en dernier : si on plante en cours d'init, on recommence
	ldi	ZL, EE_MAGIC
	ldi	w, EE_MAGIC_OK
	rcall	eeprom_write_byte

hi_load:
	; charger min EEPROM -> SRAM
	ldi	ZL, EE_MIN_LO
	rcall	eeprom_read_byte
	sts	min_temp, w
	ldi	ZL, EE_MIN_HI
	rcall	eeprom_read_byte
	sts	min_temp+1, w
	; charger max EEPROM -> SRAM
	ldi	ZL, EE_MAX_LO
	rcall	eeprom_read_byte
	sts	max_temp, w
	ldi	ZL, EE_MAX_HI
	rcall	eeprom_read_byte
	sts	max_temp+1, w
	ret

; ==============================================================
;  history_update
;  in:  a1:a0 = temperature courante (DS18B20 signed 16-bit)
;  Compare a min/max en SRAM. Si nouveau extreme : maj SRAM + EEPROM.
;  Preserve a0, a1.
; ==============================================================
history_update:
	push	a0
	push	a1
	push	b0
	push	b1
	push	ZL
	push	ZH
	ldi	ZH, 0

	; --- compare a min : si a1:a0 < min, nouveau min ---
	lds	b0, min_temp
	lds	b1, min_temp+1
	cp	a0, b0
	cpc	a1, b1			; flags = signed(a - min)
	brge	hu_check_max		; a >= min -> pas plus petit
	; nouveau min
	sts	min_temp, a0
	sts	min_temp+1, a1
	ldi	ZL, EE_MIN_LO
	mov	w, a0
	rcall	eeprom_write_byte
	ldi	ZL, EE_MIN_HI
	mov	w, a1
	rcall	eeprom_write_byte

hu_check_max:
	; --- compare a max : si max < a1:a0, nouveau max ---
	lds	b0, max_temp
	lds	b1, max_temp+1
	cp	b0, a0
	cpc	b1, a1			; flags = signed(max - a)
	brge	hu_done			; max >= a -> pas plus grand
	; nouveau max
	sts	max_temp, a0
	sts	max_temp+1, a1
	ldi	ZL, EE_MAX_LO
	mov	w, a0
	rcall	eeprom_write_byte
	ldi	ZL, EE_MAX_HI
	mov	w, a1
	rcall	eeprom_write_byte

hu_done:
	pop	ZH
	pop	ZL
	pop	b1
	pop	b0
	pop	a1
	pop	a0
	ret
