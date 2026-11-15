#!/usr/bin/env python3
"""Converte i CSV IMU originali nelle feature selezionate del modello, senza predizioni.

Uso:
    python3 convert_fall_data.py
    python3 convert_fall_data.py --data-dir data --output model_input.csv

Riusa ricampionamento, candidati, padding ed extract_features del training.
Le annotazioni falling, se presenti, vengono ignorate: esporta TUTTI i
candidati, anche quelli ambigui esclusi dall'addestramento supervisionato.
Il CSV contiene session_id, candidate_time_s e le feature nell'ordine
di models/features.json. Le prime due colonne NON sono input del modello.
Il tempo e relativo al primo timestamp della sessione. Finestre a 30 Hz,
con 1.5 s prima e post di 1.0/1.5 s secondo features.json; padding per replica.
Assi X laterale, Y verticale da in piedi, Z avanti/indietro.
Non modifica gli originali, non applica augmentation e non allena modelli.
Richiede train_fall.py accanto a questo script e le sue dipendenze.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from train_fall import (
    FS,
    RADIUS,
    SENSOR_COLUMNS,
    WINDOW_SAMPLES,
    extract_features,
    find_candidates,
    get_window,
    load_sessions,
)


def convert_data(data_dir, output, features_path):
    with features_path.open(encoding="utf-8") as stream:
        metadata = json.load(stream)
    probe = np.zeros((WINDOW_SAMPLES, 6))
    probe[:, 1] = 9.80665
    available = list(extract_features(probe))
    names = metadata.get("feature_names")
    samples = metadata.get("window_samples")
    if (
        not isinstance(names, list) or not names
        or not all(isinstance(name, str) for name in names)
        or len(set(names)) != len(names)
        or not set(names).issubset(available)
        or metadata.get("sampling_rate_hz") != FS
        or samples not in (76, WINDOW_SAMPLES)
        or metadata.get("peak_index") != RADIUS
        or metadata.get("window_columns") != SENSOR_COLUMNS
    ):
        raise ValueError(f"{features_path}: contratto delle feature incompatibile con il convertitore")
    protected = {path.resolve() for path in data_dir.glob("*/motion.csv")}
    protected.add(features_path.resolve())
    if output.resolve() in protected:
        raise ValueError(f"L'output non puo sovrascrivere un file di input: {output}")

    sessions = load_sessions(data_dir, require_annotations=False)
    rows = []
    padded = 0
    for session in sessions:
        values = session["values"]
        candidates = find_candidates(values)
        for candidate in candidates:
            window = get_window(values, candidate)[:samples]
            features = extract_features(window, names)
            rows.append([
                session["id"], float(candidate / FS),
                *[features[name] for name in names],
            ])
            padded += int(candidate < RADIUS or candidate + samples - RADIUS - 1 >= len(values))
        print(f"  {session['id']}: {len(candidates)} candidati convertiti")
    result = pd.DataFrame(rows, columns=["session_id", "candidate_time_s", *names])
    output.parent.mkdir(parents=True, exist_ok=True)
    result.to_csv(output, index=False, float_format="%.17g")
    print(
        f"Salvato {output}: {len(result)} righe, {len(names)} feature + 2 colonne "
        f"identificative; {padded} finestre replicate ai bordi. "
        "Nessuna predizione o augmentation."
    )
    return result


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", type=Path, default=root / "data")
    parser.add_argument("--output", type=Path, default=root / "model_input.csv")
    parser.add_argument("--features", type=Path, default=root / "models" / "features.json")
    args = parser.parse_args()
    convert_data(args.data_dir, args.output, args.features)


if __name__ == "__main__":
    main()
