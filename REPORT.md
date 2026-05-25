# Rapport de projet — Serre

Veronika Wannack & Raphaël Wohrer — 26.05.2026

> Brouillon Markdown. Sections alignées sur le `.tex` pour copier-coller.
> Cible : `MCU2026-GXXX.pdf`, 7 pages max, police 11 pt, marges 2 cm.

---

## Description générale

*(Page 1 — info admin, titre, intro, description sans schémas)*

Le projet implémente le contrôle d'une mini-serre à base de l'ATmega128L
sur kit STK-300. La température interne est mesurée par un capteur Dallas
DS18B20 (bus 1-wire) et comparée à une consigne réglable par l'utilisateur.
Lorsque la température dépasse la consigne, une fenêtre motorisée par servo
s'ouvre automatiquement ; elle se referme une fois la température
redescendue. L'utilisateur interagit avec le système via une télécommande
infrarouge Vivanco UR Z2 (protocole RC5) et un afficheur LCD 2×16 affiche
l'état courant.

Trois modes de fonctionnement :

- **NORMAL** : régulation automatique selon la consigne.
- **SET** : réglage de la consigne par les touches haut/bas.
- **SLEEP** : régulation suspendue, fenêtre forcée fermée.

Périphériques utilisés : télécommande IR RC5 (obligatoire) + LCD 2×16 +
servomoteur Futaba S3003 + capteur DS18B20 (1-wire). Soit 1 périphérique
obligatoire et 3 supplémentaires, au-delà du minimum requis.

---

## Manuel d'utilisation

*(Pages 2 à 4)*

### Mode d'emploi

À la mise sous tension, le système entre en mode **NORMAL** avec une
consigne par défaut de 25 °C. La télécommande commande l'ensemble du
système :

| Touche      | Code RC5 | Effet en NORMAL                   | Effet en SET            | Effet en SLEEP  |
| ----------- | -------- | --------------------------------- | ----------------------- | --------------- |
| AV          | `0x38`   | Entre en mode SET                 | Retour en NORMAL        | —               |
| CH +        | `0x20`   | —                                 | Augmente la consigne    | —               |
| CH −        | `0x21`   | —                                 | Diminue la consigne     | —               |
| VOL +       | `0x10`   | Ouverture manuelle de la fenêtre  | —                       | —               |
| VOL −       | `0x11`   | Fermeture manuelle de la fenêtre  | —                       | —               |
| POWER       | `0x0c`   | Entre en mode SLEEP               | Entre en mode SLEEP     | Retour en NORMAL |

Les codes ont été relevés directement sur la télécommande à l'aide d'un
mode de capture (affichage temporaire du dernier code reçu sur le LCD).
La touche physique « SET » du Vivanco UR Z2 n'émet aucun signal RC5
(c'est la touche de configuration interne de la télécommande
universelle) : la fonction SET du programme a donc été affectée à la
touche « AV », isolée des autres et peu sujette à confusion.

La consigne est bornée entre 5 °C et 40 °C. Entrer en mode SLEEP force la
fenêtre fermée.

### Description technique du matériel

Configuration des ports utilisée :

| Port / pin | Direction | Rôle                                |
| ---------- | --------- | ----------------------------------- |
| PE7        | entrée    | sortie du récepteur IR (TSOP, M2)   |
| PB4        | sortie    | commande PWM du servo (M4)          |
| PB5        | E/S       | ligne DQ du DS18B20 (1-wire, M5)    |
| 0x8000     | écriture  | LCD instruction register (mappé)    |
| 0xC000     | écriture  | LCD data register (mappé)           |

L'afficheur LCD HD44780U est accédé via le bus de SRAM externe ; le bit
SRE de MCUCR est mis à 1 à l'initialisation.

### Méthodes d'interruption

Deux sources d'interruption sont utilisées :

- **INT7 (PE7, front descendant)** : déclenche le décodage RC5. Le
  récepteur IR maintient la ligne haute au repos ; un front descendant
  marque le début d'une trame RC5. L'ISR (`rc5_isr`, dans `ir_rc5.asm`)
  échantillonne 14 bits, stocke la commande décodée dans `rc5_cmd` et lève
  le drapeau `rc5_new`. Le drapeau INTF7 est explicitement réinitialisé
  avant `reti` car les fronts intermédiaires du codage Manchester
  l'auraient mis à 1 pendant le décodage.
- **Timer0 (overflow)** : déclenche la lecture périodique de la
  température sur le DS18B20 et le contrôle de la fenêtre. Configuré en
  mode asynchrone (`ASSR ← (1<<AS0)`, source quartz 32 kHz externe),
  prescaler 1, l'overflow survient environ une fois par seconde. L'ISR
  (`overflow0`, dans `main.asm`) lit la température, affiche la valeur
  sur la ligne 1 du LCD, lance la prochaine conversion et applique la
  logique de régulation (ouverture / fermeture de la fenêtre).

La boucle principale tourne quant à elle en *polling coopératif* : elle
consulte les drapeaux `rc5_new` (posé par l'ISR INT7) et les valeurs de
température (mises à jour par l'ISR Timer0), puis dispatche selon le mode
courant. Ce choix d'architecture coopérative est justifié : aucun
traitement long ne bloque la boucle, les seules attentes critiques (1/4 et
T1 d'un bit RC5) sont confinées dans l'ISR INT7, et la cadence de mise à
jour du DS18B20 (750 ms) absorbe largement les ~25 ms du décodage RC5.

### Fonctionnement du programme (top-down)

```
                +---------+        +-------------+
                | main    |        | INT7 ISR    |  (rc5_isr)
                |  loop   |        | front PE7   |
                +----+----+        +------+------+
                     |                    |
                     | rcall              | écrit rc5_cmd, rc5_new
                     v                    v
                +---------+        +-------------+
                |dispatch |<-------|  SRAM état  |
                +----+----+        +------+------+
                     |                    ^
                     v                    |
   +-----------------+-----------------+  |
   | do_normal | do_set | do_sleep     |  | met à jour temp
   +-----+-----+----+---+------+-------+  |
         |          |          |          |
         v          v          v   +------+------+
   open/close   target_up/    wake | Timer0 ISR  |
   window       target_down        | overflow0   |
                                   +-------------+
```

### Présentation des modules

| Fichier            | Rôle                                                 |
| ------------------ | ---------------------------------------------------- |
| `main.asm`         | reset, vecteurs d'interruption, boucle principale, machine à états, affichage LCD |
| `ir_rc5.asm`       | ISR de décodage RC5 (INT7)                           |
| `wire1_temp2.asm`  | ISR Timer0, lecture température, contrôle de la fenêtre *(R)* |
| `lcd.asm`          | pilote HD44780U *(fourni)*                           |
| `printf.asm`       | impression formatée *(fourni)*                       |
| `wire1.asm`        | pilote 1-wire bas niveau *(fourni)*                  |
| `macros.asm`       | macros AVR générales *(fourni)*                      |
| `definitions.asm`  | définitions de registres, ports, constantes *(fourni)* |

---

## Rapport technique

*(Pages 5 à 7 — détail de l'accès aux périphériques, références)*

### Télécommande IR (RC5)

Le codage RC5 transmet 14 bits en Manchester sur une porteuse 36 kHz : 2
bits de start (MSB), 1 bit toggle, 5 bits d'adresse, 6 bits de commande
(LSB). Le récepteur (module M2) délivre l'enveloppe démodulée sur PE7, au
repos à l'état haut.

**Accès** : interruption externe INT7 configurée sur front descendant
(`EICRB ← (1<<ISC71)`), activée dans `EIMSK`. Le premier front descendant
de la trame déclenche `rc5_isr`. L'ISR attend T1/4 (échantillonnage au
milieu du premier bit), puis échantillonne PE7 toutes les T1, accumulant
les 14 bits dans le registre 2 octets `b1:b0` via `P2C` (Pin-to-Carry) et
`ROL2`. À la fin, le registre est complémenté (`com b0`), la commande
déposée dans `rc5_cmd` (SRAM), et le drapeau `rc5_new` levé. Le flag
INTF7 est ensuite explicitement effacé (`OUTI EIFR, (1<<INTF7)`) car les
transitions Manchester intermédiaires l'ont armé pendant le décodage.

**Calibration.** La constante T1 fixe la durée d'un bit RC5 utilisée pour
l'échantillonnage. Le T1 par défaut de 1870 µs s'est avéré adéquat pour
notre paire MCU/télécommande : tous les codes des boutons utilisés se
décodent correctement et de façon stable, sans nécessiter de calibration
supplémentaire à l'oscilloscope.

**Filtrage de l'auto-répétition.** Le protocole RC5 réémet la trame
toutes les ~114 ms tant qu'une touche est maintenue, et une pression
brève suffit en général à émettre 2 trames consécutives. Sans
filtrage, chaque pression déclenche donc deux fois le dispatcher (la
consigne s'incrémente de 2 au lieu de 1, par exemple). Le bit *toggle*
de RC5 (bit 11 de la trame de 14 bits) bascule à chaque nouvelle
pression mais reste identique pendant l'auto-répétition. Après les 14
`ROL2` du décodeur, il se trouve en bit 3 de `b1` ; sa valeur est
sauvegardée en SRAM (`rc5_last_tog`) puis comparée à chaque nouvelle
trame. `rc5_new` n'est levé que si le toggle a changé.

**Sauvegarde du contexte** : l'ISR sauvegarde SREG (dans `_sreg`/r1) et
empile les registres qu'elle modifie (`w`, `u`, `b0`, `b1`, `b2`), puis
les restaure avant `reti`.

### Affichage LCD (HD44780U)

L'afficheur 2×16 est accessible en SRAM mappée : le registre d'instruction
à l'adresse `0x8000` et le registre de données à `0xC000`. L'accès SRAM
externe est activé en initialisation (`MCUCR ← (1<<SRE)|(1<<SRW10)`).

La librairie `lcd.asm` fournie est utilisée telle quelle : `LCD_init`,
`LCD_home`, `LCD_wr_dr` (via `LCD_putc`), avec gestion des codes
spéciaux CR et LF (passage à la ligne 2 à l'adresse `0x40`). L'impression
formatée passe par `PRINTF LCD` (librairie `printf.asm`) qui appelle
`LCD_putc` pour chaque caractère ; les valeurs (consigne, état fenêtre)
sont lues depuis la SRAM (adresses 0x0260+) au moyen du formateur FDEC.

**Partage de l'écran entre la boucle principale et l'ISR Timer0.**
L'afficheur n'a qu'un seul curseur matériel : si la boucle principale
et l'ISR écrivaient toutes deux n'importe où, leurs séquences
`positionnement + caractères` s'entrecroiseraient et la position
courante se retrouverait corrompue. L'écran a donc été partitionné :

- **Ligne 1** (haut) appartient à `overflow0` : `LCD_home` puis
  `PRINTF "temp=XX.YY C"`, environ une fois par seconde.
- **Ligne 2** (bas) appartient à `lcd_refresh` : `LCD_lf` (déplacement
  curseur en début de ligne 2, sans toucher la ligne 1) puis
  `PRINTF` du contenu propre au mode.

Comme la boucle principale tourne très vite (plusieurs milliers
d'itérations par seconde) tandis que le rafraîchissement n'est
nécessaire qu'aux changements d'état (~quelques fois par minute), un
drapeau `lcd_dirty` (SRAM 0x0266) signale à `lcd_refresh` quand
redessiner. Le drapeau est levé par chaque transition de mode, chaque
ajustement de consigne, et chaque appel à `open_window` /
`close_window` (qu'il provienne de la télécommande ou de l'ISR de
régulation). Le reste du temps, `lcd_refresh` constate `lcd_dirty=0`
et retourne immédiatement sans toucher au LCD. Cela évite que la
boucle principale ne « martèle » l'écran en permanence et n'entre en
collision avec l'écriture de la ligne 1 par l'ISR.

Chaque routine d'affichage (`show_normal`, `show_set`, `show_sleep`)
remplit toujours 16 caractères pour la ligne 2 afin que l'image
précédente soit intégralement écrasée.

### Capteur de température DS18B20 (1-wire)

Le DS18B20 est un capteur de température numérique sur bus 1-wire,
connecté à la ligne DQ du module M5 (PORTB). Le bus est piloté en
mode bit-bang par la librairie fournie `wire1.asm` (`wire1_init`,
`wire1_reset`, `wire1_write`, `wire1_read`).

**Cadence de lecture.** Timer0 fonctionne en mode asynchrone à partir
du quartz externe 32 kHz (`ASSR = (1<<AS0)`, `TCCR0 = 1`,
`TIMSK = (1<<TOIE0)`). L'overflow se produit toutes les
~1 s, ce qui dépasse largement le temps de conversion du DS18B20
(750 ms en résolution 12 bits).

**Séquence dans `overflow0`.** À chaque overflow, l'ISR :

1. lit le scratchpad : `wire1_reset`, commande `skipROM`,
   commande `readScratchpad`, deux `wire1_read` successifs pour
   récupérer LSB puis MSB de la température. Le résultat est placé
   dans `a1:a0`, signed 16 bits au format DS18B20 (1/16 °C par LSB) ;
2. l'affiche en ligne 1 du LCD via
   `PRINTF "temp=…",FFRAC2+FSIGN,a,4,…,"C "` (le format `FFRAC2`
   gère directement la division par 16 et l'affichage de 2 décimales) ;
3. relance immédiatement la conversion suivante :
   `wire1_reset`, `skipROM`, `convertT` ;
4. compare `a1:a0` à la consigne (registre persistant `b3:b2`,
   chargé à la valeur 25 °C × 16 = 0x0190 en `reset`) ; le résultat
   `a − b` met à jour le flag N de SREG ;
5. décide de l'action sur la fenêtre :
    - `temp ≥ consigne` (N = 0) : ouvrir la fenêtre si elle est
      fermée ;
    - `temp < consigne` (N = 1) : fermer la fenêtre si elle est
      ouverte ;
    - en mode SLEEP, cette étape 4-5 est sautée intégralement et la
      fenêtre reste à l'état où SLEEP l'a forcée (fermée).

Le déclenchement est *edge-triggered* (action uniquement quand l'état
de la fenêtre doit effectivement changer), ce qui évite d'envoyer
inutilement une commande au servo à chaque overflow.

**Sauvegarde du contexte.** L'ISR sauvegarde SREG dans `_sreg` (r1)
et empile tous les registres modifiés par les appels qu'elle effectue
(LCD, PRINTF, wire1) : `w, u, char, e0, e1, c0, a0..a3, b0, b1, X, Y,
Z`. Les registres `b2`, `b3` (qui contiennent la consigne) sont
volontairement *non* sauvegardés : ils sont initialisés une fois à
`reset` et jamais modifiés par ailleurs.

### Servomoteur Futaba S3003

*(Section à compléter par R.)*

### Allocations mémoire

**Mémoire programme (Flash)** : vecteur reset à 0x0000, vecteur INT7 à
0x0010 (`INT7addr`), vecteur Timer0 overflow à 0x0020 (`OVF0addr`). Le
code utilisateur commence après la table de vecteurs.

**Mémoire de données (SRAM interne)** : variables d'état placées dans la
plage compatible avec `printf` (0x0260–0x02FF) :

| Adresse | Symbole         | Taille | Contenu                                            |
| ------- | --------------- | ------ | -------------------------------------------------- |
| 0x0260  | `mode_var`      | 1 o    | mode courant (0=NORMAL, 1=SET, 2=SLEEP)            |
| 0x0261  | `target_temp`   | 1 o    | consigne en °C (5..40)                             |
| 0x0262  | `window_open`   | 1 o    | état fenêtre (0=fermée, 1=ouverte)                 |
| 0x0263  | `rc5_cmd`       | 1 o    | dernier code RC5 décodé                            |
| 0x0264  | `rc5_new`       | 1 o    | drapeau « commande fraîche »                       |
| 0x0265  | `rc5_last_tog`  | 1 o    | dernier bit toggle RC5 (filtre auto-répétition)    |
| 0x0266  | `lcd_dirty`     | 1 o    | drapeau « ligne 2 LCD à redessiner »               |

La pile est initialisée au sommet de la SRAM (`LDSP RAMEND`).

### Fonctions placées en librairie

Outre les librairies du cours (`macros.asm`, `lcd.asm`, `printf.asm`,
`wire1.asm`), les fonctions répétitives identifiées sont :

- `dispatch` : sélection de la routine de mode par `JK` successifs.
- `lcd_refresh` : sélection de la routine d'affichage par mode.
- `target_up` / `target_down` : ajustement borné de la consigne.
- `open_window` / `close_window` : commande du servo, point d'entrée
  unique pour les déclenchements manuels et automatiques.

### Références

1. *Vivanco, Universal TV-DVB Controller UR Z2*, BDA 34873-Rev-RZ, 2013.
2. *Vishay Semiconductors, Data Formats for IR Remote Control*, Doc. 80071 Rev. 2.2, 2019.
3. *Vishay Semiconductors, IR Receiver Modules for Remote Control Systems*, Doc. 82459, 2016.
4. *Maxim Integrated, DS18B20 Programmable Resolution 1-Wire Digital Thermometer*, datasheet.
5. *Atmel, ATmega128(L) Datasheet*, document 2467.
