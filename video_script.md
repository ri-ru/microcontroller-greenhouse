# Script vidéo de démo — Contrôleur de serre intelligent

**Durée cible : ~3 minutes (max imposé par les guidelines, section 2.4.3).**
**Parler calmement. Une seule prise, pas de montage nécessaire.**

---

## [0:00 – 0:15] Introduction

*(caméra sur la carte STK-300)*

> "Bonjour, nous sommes Veronika et Raphaëlle, groupe G[XXX]. Notre projet
> est un **contrôleur de serre intelligent** réalisé autour de
> l'ATmega128L sur le kit STK-300. Le système mesure la température,
> l'affiche sur le LCD, ouvre ou ferme automatiquement une fenêtre via
> un servomoteur en fonction d'une consigne, et garde en mémoire les
> extrêmes même après une coupure de courant."

*(pointer chaque périphérique en le nommant)*

> "Quatre périphériques : **télécommande RC5 Vivanco** (périphérique
> obligatoire), **LCD 2×16**, **capteur DS18B20 en 1-wire**, et
> **servomoteur Futaba S3003**. Quatre modes : NORMAL, SET, SLEEP, et
> HISTORY."

---

## [0:15 – 0:55] Démo mode NORMAL

*(allumer la carte — attendre l'écran d'accueil "Hello gardener!" 2 s)*

> "À l'allumage, un écran d'accueil s'affiche pendant 2 secondes, puis
> on passe en **mode NORMAL**. La ligne 1 montre l'état courant —
> `Set:25C. Closed.` — et la ligne 2 se rafraîchit chaque seconde avec
> la température mesurée, ici `Temp: 23.50 C`."

*(réchauffer le capteur avec un doigt)*

> "Si je réchauffe le capteur au-dessus de la consigne, le contrôleur
> détecte le franchissement de seuil et le servomoteur ouvre la fenêtre
> tout seul. L'affichage passe à `Open`. Dès que la température
> redescend, la fenêtre se referme automatiquement."

*(appuyer sur VOL+)*

> "Je peux aussi forcer manuellement : **VOL+** ouvre, **VOL-** ferme."

---

## [0:55 – 1:25] Démo mode SET

*(appuyer sur AV)*

> "**AV** entre en **mode SET** : l'affichage montre `<EDIT>`."

*(appuyer plusieurs fois sur CH+)*

> "**CH+** augmente la consigne, **CH-** la diminue. Bornée entre
> 5 et 40 degrés."

*(appuyer à nouveau sur AV)*

> "Un nouvel appui sur AV ramène en NORMAL avec la nouvelle consigne
> active immédiatement — à chaque tick Timer0, la routine de régulation
> relit la consigne en SRAM."

---

## [1:25 – 1:50] Démo mode SLEEP

*(appuyer sur POWER)*

> "**POWER** met en **mode SLEEP**. La fenêtre est forcée fermée,
> l'écran affiche `Sleeping...` 2 secondes, puis le LCD est effacé.
> L'ISR Timer0 lève toujours son flag mais `readT` détecte le mode
> SLEEP et sort immédiatement : plus de lecture, plus d'affichage."

*(appuyer à nouveau sur POWER)*

> "Un nouvel appui rejoue l'écran d'accueil puis revient en NORMAL,
> régulation reprise."

---

## [1:50 – 2:20] Démo mode HISTORY

*(appuyer sur GUIDE)*

> "**GUIDE** entre en **mode HISTORY** : la ligne 1 montre la
> température minimale jamais mesurée, la ligne 2 la maximale. Ces
> valeurs sont stockées dans l'**EEPROM interne** de l'ATmega128, donc
> elles **survivent à une coupure de courant**. Au démarrage, on relit
> simplement l'EEPROM ; au cours de la vie du système, on ne réécrit
> que quand un nouvel extrême est franchi — typiquement quelques fois
> par jour, très loin des 100 000 cycles d'écriture garantis."

*(appuyer à nouveau sur GUIDE)*

> "Un nouvel appui sur GUIDE revient en NORMAL."

---

## [2:20 – 3:00] Points techniques

> "Côté logiciel, le système est une **machine à états à quatre modes**
> pilotée par **deux interruptions** :
>
> - **INT7** sur front descendant décode le protocole RC5 bit par bit,
>   avec filtre sur le bit toggle pour ignorer l'auto-repeat.
> - **Timer0** en mode asynchrone sur le quartz 32 kHz déborde une fois
>   par seconde.
>
> Point d'architecture important : l'ISR Timer0 ne fait **que lever
> un drapeau** `convertT_ended`. Le vrai travail — lecture DS18B20,
> mise à jour de l'historique EEPROM, régulation — est fait par la
> routine `readT` appelée depuis la boucle principale. Cela évite que
> les ~20 ms de génération PWM du servo masquent l'INT7 et fassent
> perdre des trames RC5.
>
> Le **servo** est piloté par un PWM logiciel directement dans la
> boucle principale, en TP10-style : 18 ms de pin bas, puis le travail,
> puis 1.5 ou 1.9 ms de pin haut selon la position cible. Le servo voit
> environ 50 Hz et tient sa position.
>
> **Concepts avancés mobilisés** : EEPROM pour la persistance des
> extrêmes, 1-wire pour le DS18B20, PWM logiciel pour le servo,
> ISR multiple, drapeaux SRAM pour découpler ISR et boucle principale.
>
> Merci de votre attention."

---

## Conseils de tournage

- **Garder la télécommande en main dès le début** — ne pas la chercher
  en plein milieu.
- **Tester le scénario deux fois** avant de filmer — surtout le
  franchissement de seuil (chauffer / refroidir le capteur). Prévoir une
  petite tasse d'eau tiède si le doigt ne suffit pas.
- **Vérifier qu'un extrême est déjà en EEPROM avant la démo HISTORY** —
  sinon les valeurs affichées seront les bornes initiales (+125 / -55).
  Une montée et une descente de température avant la prise suffisent.
- **Cadrer stable sur le LCD** pendant les transitions pour que le
  correcteur puisse lire.
- **Ne pas lire le script mot à mot** — ça sonne robotique. Répéter
  2-3 fois pour pouvoir paraphraser naturellement.
- **Une seule prise continue** convient (montage non requis par les
  guidelines).
- **En cas de bafouillage, continuer** — le naturel vaut mieux que la
  perfection. Ne refaire que si la démo elle-même rate.
