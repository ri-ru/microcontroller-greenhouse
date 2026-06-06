; file	eeprom.asm   target ATmega128L-4MHz-STK300
; purpose driver EEPROM interne + historique min/max temperature.
; EEPROM map (5 octets) :
;   0x00          magic (0xA5)         ; 0xFF = 1er boot, 0xA5 = donnees OK
;   0x01..0x02    min_temp (LSB, MSB)  ; format 16-bit signé à virgule fixe entre bit4 et bit5
;   0x03..0x04    max_temp (LSB, MSB)

.equ	EE_MAGIC	= 0x00
.equ	EE_MIN_LO	= 0x01
.equ	EE_MIN_HI	= 0x02
.equ	EE_MAX_LO	= 0x03
.equ	EE_MAX_HI	= 0x04
.equ	EE_MAGIC_OK	= 0xA5

eeprom_read_byte: ; ZL = adresse EEPROM (ZH = 0) ; w = read byte
ee_rd_wait:
	sbic	EECR, EEWE		; attendre fin d'ecriture eventuelle
	rjmp	ee_rd_wait
	out	EEARH, ZH
	out	EEARL, ZL
	sbi	EECR, EERE		; declencher la lecture
	in	w, EEDR
	ret


eeprom_write_byte: ;ZL = adresse ; w = value
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

history_init: ; verify if the greenhouse was already booted before -> if yes load eeprom values 
			  ;if not init at the oposites extremum possible to be overwritten by the first history_update
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

history_update: ; a1:a0 ;  Compare a min/max en SRAM. Si nouveau extreme : maj SRAM + EEPROM.
	push	a0
	push	a1
	push	b0
	push	b1
	push	ZL
	push	ZH
	ldi	ZH, 0
	lds	b0, min_temp
	lds	b1, min_temp+1
	cp	a0, b0
	cpc	a1, b1			
	brge	hu_check_max	
	sts	min_temp, a0
	sts	min_temp+1, a1
	ldi	ZL, EE_MIN_LO
	mov	w, a0
	rcall	eeprom_write_byte
	ldi	ZL, EE_MIN_HI
	mov	w, a1
	rcall	eeprom_write_byte

hu_check_max:
	lds	b0, max_temp
	lds	b1, max_temp+1
	cp	b0, a0
	cpc	b1, a1	
	brge	hu_done	
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
