#!/usr/bin/env python3
"""Collegamento Python IMU -> 38 feature -> XGBoost completo.

Importare load_full_model e predict_from_imu; caricare il modello una volta.
I canali devono essere sincronizzati: acc in m/s^2 CON gravita, gyro in rad/s.
X laterale, +Y verticale in piedi, Z avanti/indietro. Nessuna normalizzazione.
timestamp_ns e peak_timestamp_ns devono condividere lo stesso clock monotono.
Fornire almeno 1.5 s prima e dopo il candidato; nessun padding silenzioso.
Il picco e fornito dal chiamante, non ricercato tramite falling/annotazioni.
La ricerca streaming dei candidati non e implementata da questo adattatore.

Esempio CLI:
python3 glasses_fall_inference.py data/SESSION/motion.csv --peak-time-s 4.166667

Tenere train_fall.py accanto a questo file: extract_features e condivisa
con il training, non una seconda implementazione delle formule.
Dipendenze: numpy, pandas, scipy, scikit-learn, xgboost (quelle del training).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import warnings

import numpy as np
import pandas as pd
from xgboost import XGBClassifier

from train_fall import FS, RADIUS, SENSOR_COLUMNS, extract_features, feature_definitions


MODEL_PATH = Path(__file__).resolve().parent / "models" / "comparison" / "completo_model.json"
FEATURE_NAMES = tuple(item["name"] for item in feature_definitions())


def load_full_model(path=MODEL_PATH):
    """Carica una volta i parametri appresi: 200 alberi, 38 input."""
    model = XGBClassifier()
    model.load_model(path)
    if model.n_features_in_ != 38 or len(model.get_booster().get_dump()) != 200:
        raise ValueError("Modello incompatibile: attesi 38 input e 200 alberi")
    return model


def prepare_window(timestamp_ns, ax, ay, az, gx, gy, gz, *, peak_timestamp_ns):
    """Restituisce (91x6, tempo centro s) sulla griglia ancorata al primo timestamp.

    Sono ammessi NaN sensore, interpolati come nel training. Un canale deve
    avere almeno un valore valido. Timestamp duplicati/fuori ordine rifiutati.
    Buchi >100 ms sono segnalati: non corrispondono ai piccoli buchi osservati
    nel dataset. I valori acc e gyro non vengono convertiti ne riorientati.
    """
    timestamps = np.asarray(timestamp_ns)
    if (
        timestamps.ndim != 1 or len(timestamps) < 2
        or timestamps.dtype.kind not in "iu"
        or timestamps.dtype.kind == "u" and timestamps.max() > np.iinfo(np.int64).max
    ):
        raise ValueError("timestamp_ns deve contenere almeno due interi int64 in ns")
    if not isinstance(peak_timestamp_ns, (int, np.integer)):
        raise ValueError("peak_timestamp_ns deve essere un intero in ns")
    stamps = [int(value) for value in timestamps]
    if any(right <= left for left, right in zip(stamps, stamps[1:])):
        raise ValueError("Timestamp non strettamente crescenti: duplicati o fuori ordine")
    values = np.column_stack([np.asarray(channel, dtype=float) for channel in (ax, ay, az, gx, gy, gz)])
    if values.shape != (len(stamps), 6) or np.isinf(values).any():
        raise ValueError("I sei canali devono avere lunghezza uguale ai timestamp e nessun infinito")
    time = np.asarray([(stamp - stamps[0]) / 1e9 for stamp in stamps])
    peak_time = (int(peak_timestamp_ns) - stamps[0]) / 1e9
    if not 0 <= peak_time <= time[-1]:
        raise ValueError("Candidato esterno ai timestamp disponibili")
    center = int(np.floor(peak_time * FS + 0.5))
    if center < RADIUS or center + RADIUS > int(np.floor(time[-1] * FS)):
        raise ValueError("Buffer incompleto: servono 1.5 s prima e dopo il candidato sulla griglia a 30 Hz")
    if np.diff(time).max() > 0.1:
        warnings.warn("Buco IMU >100 ms: feature interpolate potenzialmente fuori distribuzione", RuntimeWarning)
    target_time = np.arange(center - RADIUS, center + RADIUS + 1) / FS
    window = np.empty((91, 6), dtype=float)
    for column in range(6):
        valid = np.isfinite(values[:, column])
        if not valid.any():
            raise ValueError(f"Canale interamente mancante: {SENSOR_COLUMNS[column]}")
        window[:, column] = np.interp(target_time, time[valid], values[valid, column])
    return window, center / FS


def predict_from_imu(
    model, timestamp_ns, ax, ay, az, gx, gy, gz, *, peak_timestamp_ns, threshold=0.5,
):
    """Input sensori -> finestra -> feature ordinate -> probabilita e decisione.

    threshold=0.5 corrisponde al confronto principale del report.
    Le soglie calibrate sugli OOF non garantiscono zero falsi allarmi futuri.
    """
    if not np.isfinite(threshold) or not 0 <= threshold <= 1:
        raise ValueError("threshold deve essere finita e compresa tra 0 e 1")
    if model.n_features_in_ != len(FEATURE_NAMES):
        raise ValueError("Numero feature modello incompatibile")
    window, center_time = prepare_window(
        timestamp_ns, ax, ay, az, gx, gy, gz, peak_timestamp_ns=peak_timestamp_ns,
    )
    features = extract_features(window, FEATURE_NAMES)
    matrix = np.asarray([[features[name] for name in FEATURE_NAMES]])
    probability = float(model.predict_proba(matrix)[0, 1])
    return {
        "probability": probability, "is_fall": probability >= threshold,
        "threshold": float(threshold), "center_time_s": center_time,
        "feature_names": list(FEATURE_NAMES), "feature_vector": matrix[0].tolist(),
        "features": features,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--peak-time-s", required=True, type=float, help="Secondi dal primo campione")
    parser.add_argument("--model", type=Path, default=MODEL_PATH)
    parser.add_argument("--threshold", type=float, default=0.5)
    args = parser.parse_args()
    if not np.isfinite(args.peak_time_s):
        parser.error("--peak-time-s deve essere finito")
    frame = pd.read_csv(args.csv, dtype={"timestamp_ns": "int64"})
    if frame.empty:
        parser.error("CSV senza campioni")
    result = predict_from_imu(
        load_full_model(args.model), frame["timestamp_ns"].to_numpy(),
        *[frame[column].to_numpy(dtype=float) for column in SENSOR_COLUMNS],
        peak_timestamp_ns=int(frame["timestamp_ns"].iloc[0]) + round(args.peak_time_s * 1e9),
        threshold=args.threshold,
    )
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
