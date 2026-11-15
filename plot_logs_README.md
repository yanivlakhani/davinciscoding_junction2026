# Grafici dei log di movimento

Richiede Python 3.10 o successivo.

```bash
python3 -m pip install -r requirements.txt
python3 plot_logs.py
```

Lo script visita le sottocartelle immediate di `data/`, legge `motion.csv` e
`session.json` e salva **`motion_plots.png` dentro ogni cartella**. Se il PNG
esiste gia, salta la cartella **prima di leggere i log**. Non modifica i dati
originali e non apre finestre grafiche.

Per una cartella diversa:

```bash
python3 plot_logs.py --data-dir /percorso/ai/dati
```

Ogni immagine contiene:

- accelerazioni X, Y, Z in tre pannelli separati;
- modulo dell'accelerazione;
- componenti del giroscopio e del magnetometro;
- orientamento come quaternione W, X, Y, Z;
- intervallo tra campioni, frequenza mediana e timestamp duplicati, con
  riferimento alla frequenza nominale della sessione quando disponibile.

Le zone rosse indicano le annotazioni `falling` gia presenti nel CSV, non un
nuovo rilevamento di cadute. I bordi sono approssimati a meta tra campioni:
non sono gli istanti esatti degli eventi. Il tempo usa `timestamp_ns`,
espresso in secondi dal primo campione. Stream con `source` o `clock_domain`
diversi hanno blocchi di grafici separati e origini indipendenti, non
sincronizzate tramite `phone_receipt_ns`.

**I log attuali contengono accelerazioni, non velocita `vx/vy/vz`.**
L'accelerometro include la gravita, come indicato dalle unita della sessione.
Lo script non integra questi valori per evitare stime di velocita fuorvianti.
Le unita sono lette da `session.json`; i campi sensore vuoti rimangono mancanti,
non diventano zeri. I timestamp fuori ordine vengono segnalati e ordinati.

Gli errori vengono stampati, le altre cartelle continuano a essere elaborate
e il processo termina con codice 1 se almeno una sessione fallisce. Il PNG
viene salvato prima su un file temporaneo, poi rinominato a scrittura conclusa.
Per rigenerare una sessione, eliminare solo il suo `motion_plots.png` e
rilanciare lo script.

Test:

```bash
python3 -m unittest discover -s tests -v
```
