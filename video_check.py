#!/usr/bin/env python3
"""
Rileva cadute nei video usando le API di Claude.

L'API di Claude non accetta file video: per ogni video estraiamo N fotogrammi
equidistanti, li inviamo come immagini insieme a un prompt e chiediamo una
risposta SI/NO (con una breve motivazione).

Uso:
    export ANTHROPIC_API_KEY="sk-ant-..."
    python analizza_video_caduta.py
    python analizza_video_caduta.py --frames 12 --csv risultati.csv

Dipendenze:
    pip install anthropic opencv-python
"""

import argparse
import base64
import csv
import glob
import json
import os
import re
import sys
import time

import cv2

MODEL_DEFAULT = "claude-sonnet-5-5"
PATTERN_DEFAULT = "dati_raccolti/**/video/*.mp4"

PROMPT = """Ti mostro {n} fotogrammi estratti in ordine cronologico da un video \
registrato da degli occhiali smart indossati da una persona. La telecamera \
e' quindi il punto di vista della persona, all'altezza dei suoi occhi.

Il video e' stato avviato automaticamente DOPO che un sensore ha rilevato \
un possibile evento di caduta. Questo significa che spesso il momento \
dell'impatto NON e' ripreso: il video puo' iniziare quando la caduta e' \
gia' avvenuta. Il video dura circa {durata:.1f} secondi e ogni fotogramma \
e' preceduto dal suo istante temporale.

Il tuo compito NON e' vedere l'istante della caduta, ma capire dallo \
stato in cui si trova la persona se una caduta e' avvenuta.

Rispondi "SI" se vedi indizi che la persona e' finita a terra, ad esempio:
- la telecamera e' a livello del suolo o molto vicina al pavimento
- l'inquadratura e' inclinata, ruotata di lato o capovolta in modo \
innaturale e resta cosi' (la persona e' sdraiata o accasciata)
- si vedono pavimento, scarpe, gambe o oggetti dal basso verso l'alto, \
da una posizione che non e' quella di una persona in piedi o seduta
- la scena e' ferma e bassa per tutto il video, oppure ci sono movimenti \
lenti e goffi di chi cerca di rialzarsi
- arrivano altre persone che si chinano o soccorrono chi e' a terra
- se la caduta e' visibile: inquadratura che precipita o ruota bruscamente \
verso il suolo

Rispondi "NO" se la telecamera resta a un'altezza normale da persona in \
piedi o seduta su una sedia, con movimenti naturali (camminare, girare la \
testa, chinarsi un attimo e rialzarsi, sedersi in modo controllato) e \
nessun indizio di essere finiti a terra.

Se la persona e' a terra ma appare chiaramente una scelta volontaria e \
tranquilla (es. sta facendo flessioni, si e' sdraiata per riposare con \
movimenti controllati), rispondi "NO" e spiegalo nel motivo. Nel dubbio \
tra le due risposte, scegli "SI" e abbassa la confidenza.

Rispondi SOLO con un oggetto JSON, senza altro testo, in questo formato:
{{"caduta": "SI" oppure "NO", "confidenza": numero tra 0 e 1, \
"motivo": "una frase breve che cita cosa hai visto"}}"""


def trova_video(pattern):
    """Restituisce i video ordinati alfabeticamente per percorso."""
    return sorted(glob.glob(pattern, recursive=True))


def estrai_fotogrammi(percorso, n_frames=8, lato_max=768, qualita_jpeg=85):
    """
    Estrae n_frames fotogrammi equidistanti.
    Ritorna (lista di (secondi, jpeg_bytes), durata_in_secondi).
    """
    cap = cv2.VideoCapture(percorso)
    if not cap.isOpened():
        raise RuntimeError("impossibile aprire il video")

    try:
        totale = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS) or 0.0
        if totale <= 0:
            raise RuntimeError("video senza fotogrammi leggibili")
        if fps <= 0:
            fps = 30.0
        durata = totale / fps

        n = min(n_frames, totale)
        if n == 1:
            indici = [0]
        else:
            indici = [round(i * (totale - 1) / (n - 1)) for i in range(n)]

        risultati = []
        for idx in indici:
            cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
            ok, frame = cap.read()
            if not ok:
                continue
            h, w = frame.shape[:2]
            scala = lato_max / max(h, w)
            if scala < 1:
                frame = cv2.resize(
                    frame, (int(w * scala), int(h * scala)),
                    interpolation=cv2.INTER_AREA,
                )
            ok, buf = cv2.imencode(
                ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, qualita_jpeg]
            )
            if ok:
                risultati.append((idx / fps, buf.tobytes()))
    finally:
        cap.release()

    if not risultati:
        raise RuntimeError("nessun fotogramma estratto")
    return risultati, durata


def costruisci_contenuto(fotogrammi, durata):
    contenuto = []
    for secondi, jpeg in fotogrammi:
        contenuto.append({"type": "text", "text": f"Fotogramma a t={secondi:.1f}s:"})
        contenuto.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/jpeg",
                "data": base64.standard_b64encode(jpeg).decode("ascii"),
            },
        })
    contenuto.append({
        "type": "text",
        "text": PROMPT.format(n=len(fotogrammi), durata=durata),
    })
    return contenuto


def interpreta_risposta(testo):
    """Estrae SI/NO, confidenza e motivo dalla risposta del modello."""
    m = re.search(r"\{.*\}", testo, re.DOTALL)
    if m:
        try:
            dati = json.loads(m.group(0))
            caduta = str(dati.get("caduta", "")).strip().upper().replace("Ì", "I")
            if caduta in ("SI", "NO"):
                return caduta, dati.get("confidenza"), str(dati.get("motivo", "")).strip()
        except json.JSONDecodeError:
            pass
    # fallback: cerca SI/NO nel testo libero
    m = re.search(r"\b(S[IÌ]|NO)\b", testo.upper())
    if m:
        return m.group(1).replace("Ì", "I"), None, testo.strip()[:200]
    return "?", None, testo.strip()[:200]


def analizza_video(client, modello, percorso, n_frames, lato_max):
    fotogrammi, durata = estrai_fotogrammi(percorso, n_frames, lato_max)
    risposta = client.messages.create(
        model=modello,
        max_tokens=300,
        messages=[{"role": "user", "content": costruisci_contenuto(fotogrammi, durata)}],
    )
    testo = "".join(b.text for b in risposta.content if b.type == "text")
    return interpreta_risposta(testo)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pattern", default=PATTERN_DEFAULT,
                    help=f"pattern dei video (default: {PATTERN_DEFAULT})")
    ap.add_argument("--model", default=MODEL_DEFAULT, help="modello Claude")
    ap.add_argument("--frames", type=int, default=8,
                    help="fotogrammi per video (default: 8)")
    ap.add_argument("--max-side", type=int, default=768,
                    help="lato massimo in pixel dei fotogrammi (default: 768)")
    ap.add_argument("--csv", help="salva i risultati anche in questo file CSV")
    args = ap.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Errore: imposta la variabile d'ambiente ANTHROPIC_API_KEY.")

    video = trova_video(args.pattern)
    if not video:
        sys.exit(f"Nessun video trovato con il pattern: {args.pattern}")

    import anthropic  # import qui cosi' --help funziona anche senza il pacchetto
    client = anthropic.Anthropic()

    print(f"Trovati {len(video)} video. Modello: {args.model}, "
          f"{args.frames} fotogrammi per video.\n")

    righe = []
    for i, percorso in enumerate(video, 1):
        t0 = time.time()
        try:
            esito, conf, motivo = analizza_video(
                client, args.model, percorso, args.frames, args.max_side
            )
        except Exception as e:  # un video fallito non ferma gli altri
            esito, conf, motivo = "ERRORE", None, str(e)
        dt = time.time() - t0

        conf_txt = f" (confidenza {conf})" if conf is not None else ""
        print(f"[{i}/{len(video)}] {percorso}")
        print(f"    Caduta: {esito}{conf_txt}  [{dt:.1f}s]")
        if motivo:
            print(f"    Motivo: {motivo}")
        print()
        righe.append([percorso, esito, conf, motivo, f"{dt:.1f}"])

    n_si = sum(1 for r in righe if r[1] == "SI")
    n_no = sum(1 for r in righe if r[1] == "NO")
    n_altro = len(righe) - n_si - n_no
    print(f"Riepilogo: {n_si} SI, {n_no} NO, {n_altro} non determinati/errori "
          f"su {len(righe)} video.")

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["video", "caduta", "confidenza", "motivo", "secondi"])
            w.writerows(righe)
        print(f"Risultati salvati in {args.csv}")


if __name__ == "__main__":
    main()