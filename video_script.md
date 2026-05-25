# Script vidéo de démo — Contrôleur de serre intelligent

**Durée cible : ~3 minutes (max imposé par les guidelines, section 2.4.3).**
**Parler calmement. Une seule prise, pas de montage nécessaire.**

---

## [0:00 – 0:20] Introduction

*(caméra sur la carte STK-300)*

> "Bonjour, nous sommes Veronika et R, groupe G[XXX]. Notre projet est un **contrôleur de serre intelligent** réalisé autour de l'ATmega128L sur le kit STK-300. Le système mesure la température, l'affiche sur le LCD, et ouvre ou ferme automatiquement une fenêtre via un servomoteur en fonction d'une consigne entrée par l'utilisateur avec une télécommande infrarouge."

*(pointer chaque périphérique en le nommant)*

> "Nous utilisons **quatre périphériques** : la **télécommande RC5 Vivanco** (le périphérique obligatoire), l'**afficheur LCD 2×16**, un **capteur de température DS18B20 en 1-wire**, et un **servomoteur**."

---

## [0:20 – 1:10] Démo mode NORMAL

*(allumer la carte — attendre l'écran d'accueil "Hello gardener!" pendant 2 s)*

> "À l'allumage, un écran d'accueil s'affiche pendant 2 secondes, puis on passe en **mode NORMAL**. La première ligne du LCD montre l'état courant — `Set:25C. Closed.` — et la deuxième ligne se rafraîchit chaque seconde avec la température mesurée, ici `Temp: 23.50 C`."

*(réchauffer le capteur avec un doigt)*

> "Si je réchauffe le capteur au-dessus de la consigne… le contrôleur détecte le franchissement de seuil et le servomoteur ouvre la fenêtre tout seul. L'affichage indique maintenant `Open`. Dès que la température redescend, la fenêtre se referme automatiquement."

*(appuyer sur VOL+)*

> "Je peux aussi forcer manuellement : **VOL+** ouvre la fenêtre, **VOL-** la ferme."

---

## [1:10 – 1:50] Démo mode SET

*(appuyer sur AV)*

> "En appuyant sur **AV**, on entre en **mode SET**. L'affichage montre `<EDIT>`, ce qui signifie que la consigne est modifiable."

*(appuyer plusieurs fois sur CH+)*

> "**CH+** augmente la consigne, **CH-** la diminue. La valeur est bornée entre 5 et 40 degrés."

*(appuyer à nouveau sur AV)*

> "Un nouvel appui sur AV ramène en mode NORMAL avec la nouvelle consigne active. La régulation automatique utilise immédiatement la valeur mise à jour."

---

## [1:50 – 2:20] Démo mode SLEEP

*(appuyer sur POWER)*

> "**POWER** met le système en **mode SLEEP**. La fenêtre est forcée fermée, l'écran affiche `Sleeping…` pendant 2 secondes, puis le LCD est effacé : l'écran reste allumé mais entièrement vide. L'ISR Timer0 devient un no-op : on ne lit même plus le capteur, plus aucun affichage ne se met à jour."

*(appuyer à nouveau sur POWER)*

> "Un nouvel appui sur POWER rejoue l'écran d'accueil `Hello gardener!` pendant 2 secondes, puis le système revient en mode NORMAL et la régulation reprend immédiatement."

---

## [2:20 – 3:00] Points techniques

> "Côté logiciel, le système est construit comme une **machine à états** à trois modes, entièrement pilotée par **interruptions** :
>
> - **INT7** sur front descendant décode le protocole RC5 bit par bit, avec un filtre sur le bit toggle pour ignorer la répétition automatique de la télécommande.
> - **Timer0** tourne en mode asynchrone sur le quartz horloger 32 kHz et déborde chaque seconde pour déclencher la lecture de température et la logique de régulation.
>
> La boucle principale ne fait que **dispatcher selon le mode courant** et rafraîchir l'écran quand quelque chose a changé. Les ISR et la boucle principale **ne s'appellent jamais directement** — elles communiquent par des **variables partagées en SRAM**, ce qui garantit la responsivité du système.
>
> Le code est organisé en **modules par responsabilité** : `ir_rc5.asm` pour le décodage RC5, `thermo.asm` pour l'ISR Timer0 et la régulation, `servo.asm` pour la commande servo, `display.asm` pour le LCD, et `main.asm` qui ne contient plus que le squelette de la machine à états.
>
> Nous utilisons le **protocole 1-wire** pour le DS18B20, du **PWM logiciel basé sur Timer** pour le servo, et les **librairies du cours** pour le LCD et printf.
>
> Merci de votre attention."

---

## Conseils de tournage

- **Garder la télécommande en main dès le début** — ne pas la chercher en plein milieu.
- **Tester le scénario deux fois** avant de filmer — surtout le franchissement de seuil (chauffer / refroidir le capteur). Prévoir une petite tasse d'eau tiède si le doigt ne suffit pas.
- **Cadrer stable sur le LCD** pendant les transitions pour que le correcteur puisse lire.
- **Ne pas lire le script mot à mot** — ça sonne robotique. Répéter 2-3 fois pour pouvoir paraphraser naturellement.
- **Une seule prise continue** convient (montage non requis par les guidelines).
- **En cas de bafouillage, continuer** — le naturel vaut mieux que la perfection. Ne refaire que si la démo elle-même rate.
