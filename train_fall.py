#!/usr/bin/env python3
"""Training offline di cadute IMU, senza modificare i CSV.

Uso: python3 train_fall.py [--data-dir data] [--output-dir models]
Il training predefinito confronta LOSO 38/25 feature x post 1.5/1.0 s,
con selezione SOLO sul training di ciascun fold. Esporta 25 feature/post 1 s
in fall_model.kt, fall_model.json, features.json, golden_tests.json.
Non riscrive i vecchi modelli UBJ/fold (che hanno un contratto precedente).
--kotlin-compiler /percorso/kotlinc abilita compilazione e verifica JVM.
Confronto completo/leggero e report unico aggiornato:
python3 train_fall.py --compare-models
Salva i due modelli in models/comparison/ e sostituisce training_report.md,
senza modificare gli export dell'app, i CSV, i plot o i vecchi modelli.
Solo fasi e nuovi plot: python3 train_fall.py --segments-only
Questa modalita crea fall_segments.json e plots_segments/, rifiutando
output gia esistenti. Non aggiorna i modelli ne i plot originali.
I PNG individuali sono salvati nelle cartelle delle rispettive sessioni.
Rigenerazione autorizzata dei soli PNG: --segments-only --overwrite-segment-plots.
Questo flag lascia invariato fall_segments.json e non modifica motion_plots.png.

segment_fall usa Nx6 campioni uniformi [ax,ay,az,gx,gy,gz], restituisce
indici assoluti nel segnale e tempi in secondi dalla sua origine.
Onset/impatto/end sono limitati a +/-3 s dal candidato. End richiede
finestre successive complete: std(|a|) su 0.5 s e variazione massima
della gravita filtrata a 0.3 Hz nei successivi 1 s sotto 5 gradi.
Got_up usa medie mobili causali di 1 s fino alla fine della sessione,
con ritorno nel cono di 30 gradi da +Y dopo esserne usciti a/dopo end.
estimated_height = 0.5*9.81*(impact-onset)^2 e SOLO un proxy balistico
non validato, anche quando onset e giroscopico. Non e un'altezza misurata.
Rotazione integrata da onset a end (null se uno dei due manca);
lato dal segno di ax medio nel secondo dopo impact: positivo=destra.
I picchi secondari sono massimi locali >15 entro +/-1 s da impact.

I vecchi modelli in loso/, ablations/, origin_audit/ e fall_model.ubj
rimangono invariati e NON corrispondono al nuovo contratto delle feature.
--output-dir cambia la cartella di base dei quattro output mobile.
Dipendenze training: numpy, pandas, scipy, xgboost, scikit-learn, m2cgen.

extract_features(window, feature_names=None) accetta 76 o 91 campioni a 30 Hz, colonne
[ax, ay, az, gx, gy, gz], con il candidato all'indice 45. Serve quindi
attendere 1.0 o 1.5 s dopo il candidato. Pre = [-1.5, 0),
post = [0, 1.0/1.5], estremo finale incluso. Le medie di gravita usano il
secondo immediatamente precedente il candidato e l'ultimo secondo post.
L'asse verticale di riferimento e +Y. Il tempo min->max e con segno.
Assi: X laterale, Y verticale in piedi, Z avanti/indietro.

Reali e sintetici rimangono in dizionari distinti in memoria, con finestre,
feature, etichette, origine, tecnica, donatori e sample_weight. Nessun dataset
augmentato viene scritto su disco. I tratti non-falling sono solo proxy di
camminata, non annotazioni verificate. Tutte le sorgenti di augmentation
appartengono al training del fold. Le ablazioni mantengono le quantita:
una ricombinazione/caso difficile rimosso e sostituito da una trasformazione.

Una caduta e un tratto contiguo falling=1, prima del ricampionamento.
Le etichette non vengono interpolate linearmente. Gli intervalli usano
i punti medi tra timestamp originali. Dati sensore mancanti ai bordi e
finestre oltre i bordi replicano il primo/ultimo campione valido.

La soglia zero-FA e calibrata sulle stesse predizioni out-of-fold usate
per riportarla: e descrittiva, non una stima indipendente della soglia
ne una garanzia per nuove sessioni. PR-AUC riguarda i candidati etichettati;
il richiamo delle cadute include anche eventi senza un candidato valido.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import platform
import re
import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import butter, find_peaks, sosfiltfilt
from scipy.spatial.transform import Rotation
from sklearn.metrics import auc, average_precision_score, precision_recall_curve, roc_auc_score
from sklearn.metrics import (
    accuracy_score, balanced_accuracy_score, confusion_matrix, f1_score,
    matthews_corrcoef, precision_score, recall_score,
)
from sklearn.model_selection import GroupKFold
from xgboost import XGBClassifier


SEED = 42
FS = 30
G = 9.80665
RADIUS = 45
WINDOW_SAMPLES = 2 * RADIUS + 1
CONTEXT_RADIUS = 60
SENSOR_COLUMNS = [
    "accelerometer_x", "accelerometer_y", "accelerometer_z",
    "gyroscope_x", "gyroscope_y", "gyroscope_z",
]
GRAVITY_FILTER = butter(2, 0.3, fs=FS, output="sos")
TECHNIQUES = (
    "rotation", "scale", "warp", "shift", "noise", "drop", "mirror",
    "recombination", "negative_impact", "negative_gyro",
)
PHASE_COLORS = {
    "PRIMA": "gray", "CADUTA": "tab:orange", "DOPO URTO": "tab:purple",
    "A TERRA": "tab:blue", "RIALZATO": "tab:green",
}


def gravity_signal(sig, fs):
    if len(sig) < 10:
        raise ValueError("Servono almeno 10 campioni per stimare la gravita")
    return sosfiltfilt(
        butter(2, 0.3, fs=fs, output="sos"), sig[:, :3], axis=0,
        padlen=min(9, len(sig) - 1),
    )


def vector_angle(first, second):
    denominator = np.linalg.norm(first, axis=-1) * np.linalg.norm(second, axis=-1)
    cosine = np.divide(
        np.sum(first * second, axis=-1), denominator,
        out=np.full(np.shape(denominator), np.nan), where=denominator > 1e-8,
    )
    return np.degrees(np.arccos(np.clip(cosine, -1, 1)))


def segment_fall(sig, peak_idx, fs=30):
    """Fasi euristiche offline: valori assenti = None, nessun bordo inventato."""
    sig = np.asarray(sig, dtype=float)
    if (
        sig.ndim != 2 or sig.shape[1] != 6 or not np.isfinite(sig).all()
        or not np.isfinite(fs) or fs <= 0.6
        or not isinstance(peak_idx, (int, np.integer))
        or not 0 <= peak_idx < len(sig)
    ):
        raise ValueError("Attesi segnale Nx6 finito, indice valido e fs > 0.6 Hz")
    radius, half, second = int(round(3 * fs)), max(2, int(round(0.5 * fs))), int(round(fs))
    left, right = max(0, peak_idx - radius), min(len(sig) - 1, peak_idx + radius)
    acc = np.linalg.norm(sig[:, :3], axis=1)
    omega = np.linalg.norm(sig[:, 3:], axis=1)
    impact = int(left + np.argmax(acc[left:right + 1]))
    freefall = np.flatnonzero(acc[left:impact] < 0.6 * G)
    rotating = np.flatnonzero(omega[left:impact] > 3)
    onset = int(left + freefall[-1]) if freefall.size else (
        int(left + rotating[-1]) if rotating.size else None
    )
    onset_basis = "freefall" if freefall.size else ("gyroscope" if rotating.size else None)
    peaks = find_peaks(np.r_[-np.inf, acc, -np.inf])[0] - 1
    secondary = [
        int(index) for index in peaks
        if index != impact and acc[index] > 15 and abs(index - impact) <= fs
        and left <= index <= right
    ]
    gravity = gravity_signal(sig, fs)
    end = None
    for index in range(impact + 1, right - second + 1):
        if index + half > len(sig):
            break
        variation = vector_angle(gravity[index:index + second + 1], gravity[index])
        if (
            acc[index:index + half].std() < 0.5
            and np.isfinite(variation).all() and variation.max() < 5
        ):
            end = index
            break
    got_up_idx = None
    if end is not None:
        outside = False
        for index in range(max(end, second - 1), len(sig)):
            mean_gravity = sig[index - second + 1:index + 1, :3].mean(axis=0)
            angle = float(vector_angle(mean_gravity, np.array([0., 1., 0.])))
            if not np.isfinite(angle):
                continue
            if angle > 30:
                outside = True
            elif outside and index > end:
                got_up_idx = index
                break
    duration = (impact - onset) / fs if onset is not None else None
    post = sig[impact + 1:min(len(sig), impact + second + 1), 0]
    post_x = float(post.mean()) if post.size else None
    side = None if post_x is None else (
        "destra" if post_x > 0 else ("sinistra" if post_x < 0 else "indeterminato")
    )
    rotation = None
    if onset is not None and end is not None:
        rotation = float(np.trapezoid(omega[onset:end + 1], dx=1 / fs))
    return {
        "window_start_idx": left, "window_end_idx": right,
        "onset": onset, "onset_basis": onset_basis, "impact": impact,
        "secondary_impacts": secondary, "end": end,
        "got_up": got_up_idx is not None, "got_up_idx": got_up_idx,
        "onset_time": onset / fs if onset is not None else None,
        "impact_time": impact / fs,
        "secondary_impact_times": [index / fs for index in secondary],
        "end_time": end / fs if end is not None else None,
        "got_up_time": got_up_idx / fs if got_up_idx is not None else None,
        "fall_duration": duration,
        "estimated_height": 0.5 * 9.81 * duration ** 2 if duration is not None else None,
        "estimated_height_validated": False,
        "peak_acc": float(acc[impact]), "n_impacts": 1 + len(secondary),
        "rotation_integrated": rotation, "side": side, "post_ax_mean": post_x,
        "time_to_still": (end - impact) / fs if end is not None else None,
    }


def phase_spans(segment, session_end):
    onset, impact, end, got_up = (
        segment["onset_time"], segment["impact_time"],
        segment["end_time"], segment["got_up_time"],
    )
    spans = []
    if onset is not None:
        spans.extend([
            ("PRIMA", segment["window_start_time"], onset),
            ("CADUTA", onset, impact),
        ])
    if end is not None:
        spans.extend([
            ("DOPO URTO", impact, end),
            ("A TERRA", end, got_up if got_up is not None else session_end),
        ])
    if got_up is not None:
        spans.append(("RIALZATO", got_up, session_end))
    return spans


def decorate_segment(axis, session, offset=0, annotate=True):
    for start, stop in session["intervals"]:
        axis.axvspan(start - offset, stop - offset, color="tab:red", alpha=0.13)
    for segment in session["segments"]:
        for name, start, stop in phase_spans(segment, float(session["time"][-1])):
            axis.axvspan(start - offset, stop - offset, color=PHASE_COLORS[name], alpha=0.14)
        markers = [
            ("onset", segment["onset_time"]), ("impact", segment["impact_time"]),
            *[("secondary_impact", time) for time in segment["secondary_impact_times"]],
            ("end", segment["end_time"]), ("got_up", segment["got_up_time"]),
        ]
        for number, (name, time) in enumerate(markers):
            if time is not None:
                axis.axvline(time - offset, color="black", linestyle="--", linewidth=0.7, alpha=0.65)
                if annotate:
                    axis.text(
                        time - offset, 0.98 - 0.09 * (number % 3), name,
                        transform=axis.get_xaxis_transform(), rotation=90,
                        fontsize=7, va="top",
                    )
    axis.grid(alpha=0.25)


def segment_legend(axis, fontsize=7):
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch

    descriptions = {
        "PRIMA": "Prima della caduta",
        "CADUTA": "Caduta: onset -> impatto",
        "DOPO URTO": "Dopo urto: impatto -> immobilita",
        "A TERRA": "A terra (fase stimata)",
        "RIALZATO": "Rialzato (ritorno verso +Y)",
    }
    handles, _ = axis.get_legend_handles_labels()
    handles.extend(
        Patch(color=color, alpha=0.25, label=descriptions[name])
        for name, color in PHASE_COLORS.items()
    )
    handles.extend([
        Patch(color="tab:red", alpha=0.13, label="Rosso: falling annotato"),
        Line2D([], [], color="black", linestyle="--", linewidth=0.7,
               label="Tratteggi: eventi automatici"),
    ])
    axis.legend(handles=handles, loc="upper left", bbox_to_anchor=(0, -0.15),
                ncol=3, fontsize=fontsize, framealpha=0.95)


def plot_fall_segments(session, overwrite=False):
    """Salva nella cartella della sessione; sovrascrive solo con consenso."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    directory = session["directory"]
    output = directory / f"{session['id']}_segments.png"
    if output.exists() and not overwrite:
        raise FileExistsError(f"PNG gia esistente, serve autorizzazione: {output}")
    values, time = session["values"], session["time"]
    figure, axes = plt.subplots(7, 1, figsize=(18, 26), sharex=True)
    try:
        figure.suptitle(
            f"{session['id']} - Fasi calcolate automaticamente (non annotazione)", fontsize=14,
        )
        for index, (name, description) in enumerate((
            ("ax", "X laterale"), ("ay", "Y verticale in piedi"),
            ("az", "Z avanti/indietro"),
        )):
            axes[index].plot(time, values[:, index], label=f"{name}: accelerazione {description}",
                             color=("tab:blue", "tab:orange", "tab:green")[index], linewidth=1)
            axes[index].set_ylabel(f"{name} [m/s^2]")
        axes[3].plot(time, np.linalg.norm(values[:, :3], axis=1), linewidth=1,
                     label="|a|: modulo accelerazione, include gravita")
        axes[3].set_ylabel("|a| [m/s^2]")
        axes[3].axhline(0.6 * G, color="tab:orange", linestyle=":", label="0.6 g: soglia caduta libera")
        axes[3].axhline(15, color="tab:red", linestyle=":", label="15 m/s^2: soglia urto")
        for index, name in enumerate(("gx", "gy", "gz")):
            axes[4].plot(time, values[:, 3 + index], label=f"{name}: velocita angolare asse {'XYZ'[index]}", linewidth=1)
        axes[4].set_ylabel("Giroscopio [rad/s]")
        axes[5].plot(time, np.linalg.norm(values[:, 3:], axis=1), linewidth=1,
                     label="|omega|: modulo velocita angolare")
        axes[5].set_ylabel("|omega| [rad/s]")
        angles = vector_angle(gravity_signal(values, FS), np.array([0., 1., 0.]))
        axes[6].plot(time, angles, linewidth=1,
                     label="Gravita vs +Y: 0 gradi = verticale in piedi")
        axes[6].set_ylabel("Gravita vs +Y [gradi]")
        axes[6].set_xlabel("Tempo dal primo campione [s]")
        for axis in axes:
            decorate_segment(axis, session)
            axis.tick_params(labelbottom=True)
            segment_legend(axis)
        boxes = []
        for event, segment in enumerate(session["segments"], start=1):
            lines = [f"Caduta {event}"]
            for key, unit in (
                ("fall_duration", "s"), ("estimated_height", "m (proxy non validato)"),
                ("peak_acc", "m/s^2"), ("n_impacts", ""), ("rotation_integrated", "rad"),
                ("side", ""), ("time_to_still", "s"), ("got_up", ""),
            ):
                value = segment[key]
                text = f"{value:.3f}" if isinstance(value, float) else str(value)
                lines.append(f"{key}: {'non disponibile' if value is None else text} {unit}")
            if segment["got_up"]:
                lines.append(f"got_up_time: {segment['got_up_time']:.3f} s")
            for key in ("onset", "end"):
                if segment[key] is None:
                    lines.append(f"{key} non trovato")
            boxes.append("\n".join(lines))
        figure.text(
            0.81, 0.94, "\n\n".join(boxes), ha="left", va="top", fontsize=9,
            bbox={"boxstyle": "round", "facecolor": "white", "edgecolor": "gray", "alpha": 0.95},
        )
        handles = [Patch(color=color, alpha=0.25, label=name) for name, color in PHASE_COLORS.items()]
        handles.append(Patch(color="tab:red", alpha=0.13, label="falling annotato"))
        figure.legend(handles=handles, loc="lower center", ncol=6, fontsize=9)
        figure.subplots_adjust(left=0.08, right=0.79, top=0.95, bottom=0.08, hspace=0.65)
        with output.open("wb" if overwrite else "xb") as stream:
            figure.savefig(stream, format="png", dpi=150)
    finally:
        plt.close(figure)
    return output


def export_fall_segments(sessions, overwrite_plots=False):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    root = Path(__file__).resolve().parent
    directory, output = root / "plots_segments", root / "fall_segments.json"
    if not overwrite_plots and (
        directory.exists() or output.exists()
        or any((session["directory"] / f"{session['id']}_segments.png").exists()
               for session in sessions if session["segments"])
    ):
        raise FileExistsError(
            "plots_segments/ o fall_segments.json gia esistente: chiedere "
            "autorizzazione prima di sovrascrivere. Nessun output modificato."
        )
    directory.mkdir(exist_ok=overwrite_plots)
    fall_sessions = [session for session in sessions if session["segments"]]
    created = [plot_fall_segments(session, overwrite=overwrite_plots) for session in fall_sessions]
    events = [(session, segment) for session in fall_sessions for segment in session["segments"]]
    if not events:
        raise ValueError("Nessuna caduta annotata da visualizzare")
    columns = 3
    rows = int(np.ceil(len(events) / columns))
    figure, axes = plt.subplots(rows, columns, figsize=(24, 5.5 * rows), squeeze=False)
    try:
        for axis, (session, segment) in zip(axes.flat, events):
            offset = segment["impact_time"]
            axis.plot(session["time"] - offset, np.linalg.norm(session["values"][:, :3], axis=1),
                      linewidth=1, label="|a|: modulo accelerazione")
            one_event = {**session, "segments": [segment]}
            decorate_segment(axis, one_event, offset, annotate=False)
            axis.axhline(0.6 * G, color="tab:orange", linestyle=":", linewidth=0.7, label="0.6 g: caduta libera")
            axis.axhline(15, color="tab:red", linestyle=":", linewidth=0.7, label="15 m/s^2: urto")
            segment_legend(axis, fontsize=6)
            axis.set_xlim(-3, 3)
            axis.set_title(session["id"], fontsize=8)
            axis.set_xlabel("Tempo dall'impatto [s]")
            axis.set_ylabel("|a| [m/s^2]")
            missing = [key for key in ("onset", "end") if segment[key] is None]
            if missing:
                axis.text(0.02, 0.92, "/".join(missing) + " non trovato",
                          transform=axis.transAxes, fontsize=8)
        for axis in list(axes.flat)[len(events):]:
            axis.set_visible(False)
        figure.suptitle("Fasi calcolate automaticamente (non annotazione) - impatto a t=0")
        figure.legend(
            handles=[Patch(color=color, alpha=0.25, label=name) for name, color in PHASE_COLORS.items()]
            + [Patch(color="tab:red", alpha=0.13, label="falling annotato")],
            loc="lower center", ncol=6,
        )
        figure.tight_layout(rect=(0, 0.03, 1, 0.97))
        overview = directory / "overview.png"
        with overview.open("wb" if overwrite_plots else "xb") as stream:
            figure.savefig(stream, format="png", dpi=150)
        created.append(overview)
    finally:
        plt.close(figure)
    if overwrite_plots:
        print("\nPlot aggiornati (JSON e altri file invariati):")
        for path in created:
            print(path)
        return created
    payload = {
        "sampling_rate_hz": FS,
        "method": {
            "search_window_s": 3, "freefall_threshold_m_s2": 0.6 * G,
            "gyro_onset_threshold_rad_s": 3, "impact_threshold_m_s2": 15,
            "end_std_threshold_m_s2": 0.5, "end_std_window_s": 0.5,
            "end_gravity_angle_deg": 5, "end_gravity_window_s": 1,
            "gravity_lowpass_hz": 0.3, "got_up_cone_deg": 30,
            "got_up_mean_window_s": 1,
            "estimated_height": "0.5*9.81*fall_duration^2; proxy balistico NON VALIDATO, anche con onset giroscopico",
            "side": "segno ax medio nel secondo dopo impact: positivo destra, negativo sinistra",
            "missing_values": "null; nessun onset/end sostitutivo",
            "indices": "assoluti nella sessione ricampionata; tempi in secondi dal primo campione",
            "got_up": "ritorno entro 30 gradi da +Y dopo uscita osservata a/dopo end; False non prova mancata rialzata",
            "rotation_integrated": "integrale trapezoidale |omega| da onset a end; null se manca un estremo",
        },
        "sessions": [
            {"session_id": session["id"], "annotated_intervals_s": session["intervals"],
             "segments": session["segments"]} for session in fall_sessions
        ],
    }
    with output.open("x", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, allow_nan=False)
        stream.write("\n")
    created.append(output)
    print("\nFile creati:")
    for path in created:
        print(path)
    return created


def feature_definitions():
    definitions = []
    for segment in ("pre", "post"):
        for suffix, formula, unit in (
            ("a_max", "max(a)", "m/s^2"),
            ("a_min", "min(a)", "m/s^2"),
            ("a_mean", "mean(a)", "m/s^2"),
            ("a_std", "sqrt(mean((a-mean(a))^2)); ddof=0", "m/s^2"),
            ("a_range", "max(a)-min(a)", "m/s^2"),
            ("jerk_max", "30*max(abs(a[i+1]-a[i]))", "m/s^3"),
            ("low_g_count", "sum(a < 0.6*9.80665)", "samples"),
            ("min_to_max_s", "(first_argmax(a)-first_argmin(a))/30; signed", "s"),
        ):
            definitions.append({"name": f"{segment}_{suffix}", "segment": segment,
                                "formula": formula, "unit": unit})
        for axis in "xyz":
            for operation, formula in (
                ("mean", f"mean(a{axis})"),
                ("std", f"sqrt(mean((a{axis}-mean(a{axis}))^2)); ddof=0"),
            ):
                definitions.append({"name": f"{segment}_a{axis}_{operation}",
                                    "segment": segment, "formula": formula, "unit": "m/s^2"})
        for suffix, formula, unit in (
            ("omega_max", "max(omega)", "rad/s"),
            ("omega_mean", "mean(omega)", "rad/s"),
            ("rotation_rad", "sum(omega)/30; rectangular sum", "rad"),
        ):
            definitions.append({"name": f"{segment}_{suffix}", "segment": segment,
                                "formula": formula, "unit": unit})
    for name, formula, unit in (
        ("gravity_pre_post_deg", "angle(mean(acc[15:45]), mean(acc[-30:]))", "deg"),
        ("gravity_post_y_deg", "angle(mean(acc[-30:]), [0,1,0])", "deg"),
        ("last_second_a_std", "sqrt(mean((a[-30:]-mean(a[-30:]))^2)); ddof=0", "m/s^2"),
        ("last_second_omega_mean", "mean(omega[-30:])", "rad/s"),
    ):
        definitions.append({"name": name, "segment": "last/pre second",
                            "formula": formula, "unit": unit})
    return definitions


def extract_features(window, feature_names=None):
    """Unica estrazione per training, augmentation e inferenza in tempo reale."""
    window = np.asarray(window, dtype=np.float64)
    if window.shape not in ((76, 6), (WINDOW_SAMPLES, 6)) or not np.isfinite(window).all():
        raise ValueError("window deve essere finita e di forma (76, 6) o (91, 6)")
    operations = {}
    for name, segment in (("pre", window[:RADIUS]), ("post", window[RADIUS:])):
        acc = np.linalg.norm(segment[:, :3], axis=1)
        gyro = np.linalg.norm(segment[:, 3:], axis=1)
        operations.update({
            f"{name}_a_max": lambda a=acc: float(a.max()),
            f"{name}_a_min": lambda a=acc: float(a.min()),
            f"{name}_a_mean": lambda a=acc: float(a.mean()),
            f"{name}_a_std": lambda a=acc: float(a.std(ddof=0)),
            f"{name}_a_range": lambda a=acc: float(a.max() - a.min()),
            f"{name}_jerk_max": lambda a=acc: float(np.abs(np.diff(a)).max() * FS),
            f"{name}_low_g_count": lambda a=acc: float(np.count_nonzero(a < 0.6 * G)),
            f"{name}_min_to_max_s": lambda a=acc: float((a.argmax() - a.argmin()) / FS),
        })
        for index, axis in enumerate("xyz"):
            values = segment[:, index]
            operations[f"{name}_a{axis}_mean"] = lambda a=values: float(a.mean())
            operations[f"{name}_a{axis}_std"] = lambda a=values: float(a.std(ddof=0))
        operations[f"{name}_omega_max"] = lambda a=gyro: float(a.max())
        operations[f"{name}_omega_mean"] = lambda a=gyro: float(a.mean())
        operations[f"{name}_rotation_rad"] = lambda a=gyro: float(a.sum() / FS)

    gravity_pre = window[RADIUS - FS:RADIUS, :3].mean(axis=0)
    gravity_post = window[-FS:, :3].mean(axis=0)
    pre_norm = np.linalg.norm(gravity_pre)
    post_norm = np.linalg.norm(gravity_post)
    if min(pre_norm, post_norm) < 1e-8:
        raise ValueError("Gravita media quasi nulla: angolo non definito")
    cosine = np.dot(gravity_pre, gravity_post) / (pre_norm * post_norm)
    operations["gravity_pre_post_deg"] = lambda: float(np.degrees(np.arccos(np.clip(cosine, -1, 1))))
    operations["gravity_post_y_deg"] = lambda: float(
        np.degrees(np.arccos(np.clip(gravity_post[1] / post_norm, -1, 1)))
    )
    operations["last_second_a_std"] = lambda: float(np.linalg.norm(window[-FS:, :3], axis=1).std(ddof=0))
    operations["last_second_omega_mean"] = lambda: float(
        np.linalg.norm(window[-FS:, 3:], axis=1).mean()
    )
    names = list(operations) if feature_names is None else list(feature_names)
    if len(set(names)) != len(names) or not names or not set(names).issubset(operations):
        raise ValueError("Nomi feature duplicati, vuoti o non riconosciuti")
    return {name: operations[name]() for name in names}


def load_sessions(data_dir, require_annotations=True):
    paths = sorted(data_dir.glob("*/motion.csv"))
    if not paths:
        raise ValueError(f"Nessun CSV trovato in {data_dir}")
    sessions = []
    required = [
        "session_id", "timestamp_ns", "source", "clock_domain",
        *SENSOR_COLUMNS,
    ]
    if require_annotations:
        required.append("falling")
    for path in paths:
        frame = pd.read_csv(
            path, dtype={"session_id": str, "timestamp_ns": "int64"},
        )
        missing = set(required).difference(frame.columns)
        if missing:
            raise ValueError(f"{path}: colonne mancanti: {sorted(missing)}")
        identifiers = frame["session_id"].unique()
        if len(identifiers) != 1 or identifiers[0] != path.parent.name:
            raise ValueError(f"{path}: session_id non unico o diverso dalla cartella")
        if frame[["source", "clock_domain"]].isna().any().any():
            raise ValueError(f"{path}: source/clock_domain mancante")
        if len(frame[["source", "clock_domain"]].drop_duplicates()) != 1:
            raise ValueError(f"{path}: piu stream o domini temporali nella stessa sessione")
        if len(frame) < 2 or (
            require_annotations and not frame["falling"].isin([0, 1]).all()
        ):
            raise ValueError(f"{path}: dati insufficienti o falling non binario")
        if not frame["timestamp_ns"].is_monotonic_increasing:
            print(f"  AVVISO {path.parent.name}: timestamp riordinati", flush=True)
        frame = frame.sort_values("timestamp_ns", kind="stable").reset_index(drop=True)
        if frame["timestamp_ns"].duplicated().any():
            raise ValueError(f"{path}: timestamp duplicati; risolvere la loro ambiguita")
        timestamps = frame["timestamp_ns"].to_numpy(dtype=np.int64)
        time = (timestamps - timestamps[0]).astype(np.float64) / 1e9
        uniform_time = np.arange(int(np.floor(time[-1] * FS)) + 1) / FS
        if len(uniform_time) < 2:
            raise ValueError(f"{path}: durata inferiore a un intervallo a 30 Hz")
        sensor = frame[SENSOR_COLUMNS].to_numpy(dtype=np.float64)
        if np.isinf(sensor).any():
            raise ValueError(f"{path}: valori sensore infiniti")
        values = np.empty((len(uniform_time), 6), dtype=np.float64)
        for index, column in enumerate(SENSOR_COLUMNS):
            valid = np.isfinite(sensor[:, index])
            if not valid.any():
                raise ValueError(f"{path}: {column} interamente mancante")
            values[:, index] = np.interp(
                uniform_time, time[valid], sensor[valid, index],
            )
        flag = (
            frame["falling"].to_numpy(dtype=bool) if require_annotations
            else np.zeros(len(frame), dtype=bool)
        )
        transitions = np.diff(np.r_[False, flag, False].astype(int))
        starts = np.flatnonzero(transitions == 1)
        stops = np.flatnonzero(transitions == -1)
        edges = np.r_[time[0], (time[:-1] + time[1:]) / 2, time[-1]]
        intervals = [(float(edges[start]), float(edges[stop]))
                     for start, stop in zip(starts, stops)]
        norm = np.linalg.norm(values[:, :3], axis=1)
        impacts = []
        for start, stop in intervals:
            inside = np.flatnonzero((uniform_time >= start) & (uniform_time <= stop))
            if not inside.size:
                raise ValueError(f"{path}: caduta troppo breve per la griglia a 30 Hz")
            impacts.append(int(inside[np.argmax(norm[inside])]))
        segments = []
        for event, impact in enumerate(impacts):
            segment = segment_fall(values, impact, FS)
            segment["annotated_peak_idx"] = impact
            segment["annotated_interval_s"] = list(intervals[event])
            segment["window_start_time"] = segment["window_start_idx"] / FS
            segment["window_end_time"] = segment["window_end_idx"] / FS
            segments.append(segment)
        nonfall_seconds = float(time[-1] - sum(stop - start for start, stop in intervals))
        sessions.append({
            "id": identifiers[0], "values": values, "time": uniform_time,
            "directory": path.parent,
            "intervals": intervals, "impacts": impacts,
            "segments": segments,
            "nonfall_seconds": nonfall_seconds,
        })
        print(
            f"  {identifiers[0]}: {time[-1]:.2f} s, "
            f"{str(len(intervals)) + ' cadute' if require_annotations else 'annotazioni ignorate'}, "
            f"{np.isnan(sensor).sum()} valori mancanti interpolati, "
            f"buco max {np.diff(time).max():.3f} s",
            flush=True,
        )
    return sessions


def find_candidates(values):
    """Massimi >15 o minimi <0.6g; soppressione unica a distanza <1 s."""
    norm = np.linalg.norm(values[:, :3], axis=1)
    high = find_peaks(np.r_[-np.inf, norm, -np.inf])[0] - 1
    low = find_peaks(np.r_[-np.inf, -norm, -np.inf])[0] - 1
    candidates = np.unique(np.r_[high[norm[high] > 15], low[norm[low] < 0.6 * G]])
    # La priorita dipende solo dal segnale, mai dall'annotazione falling.
    ranked = sorted(candidates.tolist(), key=lambda i: (-abs(norm[i] - G), i))
    selected = []
    for candidate in ranked:
        if all(abs(candidate - previous) >= FS for previous in selected):
            selected.append(candidate)
    return np.array(sorted(selected), dtype=int)


def get_window(values, center, radius=RADIUS):
    indices = np.arange(center - radius, center + radius + 1)
    return values[np.clip(indices, 0, len(values) - 1)].copy()


def make_dataset(sessions):
    contexts, labels, groups, event_ids = [], [], [], []
    feature_rows = []
    feature_names = None
    padded = context_padded = discarded = candidate_count = 0
    for session in sessions:
        values = session["values"]
        candidates = find_candidates(values)
        candidate_count += len(candidates)
        # Matching uno-a-uno al candidato piu vicino all'urto, entro 0.3 s.
        pairs = sorted(
            (abs(int(candidate) - impact), event, int(candidate))
            for event, impact in enumerate(session["impacts"])
            for candidate in candidates if abs(int(candidate) - impact) <= 0.3 * FS
        )
        positives = {}
        matched_events = set()
        for _, event, candidate in pairs:
            if candidate not in positives and event not in matched_events:
                positives[candidate] = event
                matched_events.add(event)
        negative_count = 0
        for candidate in candidates:
            time = candidate / FS
            if candidate in positives:
                label = 1
                event_id = f"{session['id']}:{positives[candidate]}"
                center = session["segments"][positives[candidate]]["impact"]
            elif all(time < start - 1 or time > stop + 1
                     for start, stop in session["intervals"]):
                label = 0
                event_id = ""
                center = int(candidate)
                negative_count += 1
            else:
                discarded += 1
                continue
            window = get_window(values, center)
            features = extract_features(window)
            if feature_names is None:
                feature_names = list(features)
            if list(features) != feature_names:
                raise ValueError("Ordine delle feature incoerente")
            feature_rows.append(list(features.values()))
            contexts.append(get_window(values, center, CONTEXT_RADIUS))
            labels.append(label)
            groups.append(session["id"])
            event_ids.append(event_id)
            padded += int(center < RADIUS or center + RADIUS >= len(values))
            context_padded += int(
                center < CONTEXT_RADIUS or center + CONTEXT_RADIUS >= len(values)
            )
        print(
            f"  {session['id']}: {len(candidates)} candidati, "
            f"{len(positives)}/{len(session['impacts'])} cadute con candidato, "
            f"{negative_count} negativi",
            flush=True,
        )
    if not feature_rows or feature_names is None or len(set(labels)) != 2:
        raise ValueError("Servono candidati positivi e negativi per allenare il modello")
    print(
        f"Passi 2-3 completati: {candidate_count} candidati, "
        f"{sum(labels)} positivi, {len(labels) - sum(labels)} negativi, "
        f"{discarded} ambigui scartati; {len(feature_names)} feature. "
        f"Finestre replicate ai bordi: {padded}/{len(labels)} "
        f"(contesti augmentation: {context_padded}/{len(labels)}).",
        flush=True,
    )
    return (
        np.asarray(feature_rows), np.stack(contexts),
        np.asarray(labels, dtype=int), np.asarray(groups), np.asarray(event_ids),
        feature_names,
    )


def augment_window(context, gravity, rng, omitted=None, mirror=False):
    """Trasforma il contesto, poi estrae la finestra senza ricentrare il picco."""
    acceleration_scale, gyro_scale = rng.uniform(0.8, 1.2, size=2)
    transformed = context.copy()
    if omitted != "scale":
        transformed[:, :3] = gravity + acceleration_scale * (context[:, :3] - gravity)
        transformed[:, 3:] *= gyro_scale
    if mirror and omitted != "mirror":
        transformed[:, 0] *= -1
        gravity = gravity.copy()
        gravity[:, 0] *= -1
        transformed[:, 4:6] *= -1
    rotation_axis = rng.normal(size=3)
    rotation_axis /= np.linalg.norm(rotation_axis)
    rotation = Rotation.from_rotvec(rotation_axis * np.deg2rad(rng.uniform(-15, 15)))
    if omitted != "rotation":
        transformed[:, :3] = rotation.apply(transformed[:, :3])
        transformed[:, 3:] = rotation.apply(transformed[:, 3:])
        gravity = rotation.apply(gravity)

    time = np.arange(-RADIUS, RADIUS + 1) / FS
    phase = rng.uniform(0, 2 * np.pi)
    # Derivata in [0.9, 1.1]; il centro originale cade esattamente a shift.
    amplitude = rng.uniform(-0.1, 0.1) * 3 / (2 * np.pi)
    shift = rng.uniform(-0.3, 0.3)
    if omitted == "warp":
        amplitude = 0.0
    if omitted == "shift":
        shift = 0.0
    shifted_time = time - shift
    warped = shifted_time + amplitude * (
        np.sin(2 * np.pi * shifted_time / 3 + phase) - np.sin(phase)
    )
    context_time = np.arange(-CONTEXT_RADIUS, CONTEXT_RADIUS + 1) / FS
    if warped.min() < context_time[0] or warped.max() > context_time[-1]:
        raise ValueError("Contesto insufficiente per time warp e traslazione")
    window = np.column_stack([
        np.interp(warped, context_time, transformed[:, index]) for index in range(6)
    ])
    # La compressione temporale aumenta l'ampiezza dinamica dell'urto,
    # non la gravita. Compensazione locale, raccordata fuori da +/-0.2 s.
    compression = 1 + amplitude * (2 * np.pi / 3) * np.cos(
        2 * np.pi * shifted_time / 3 + phase
    )
    warped_gravity = np.column_stack([
        np.interp(warped, context_time, gravity[:, index]) for index in range(3)
    ])
    impact_envelope = np.exp(-0.5 * (warped / 0.15) ** 2)
    window[:, :3] = warped_gravity + (window[:, :3] - warped_gravity) * (
        1 + (compression - 1) * impact_envelope
    )[:, None]
    acceleration_noise = rng.normal(0, 0.15, size=(WINDOW_SAMPLES, 3))
    gyro_noise = rng.normal(0, 0.03, size=(WINDOW_SAMPLES, 3))
    if omitted != "noise":
        window[:, :3] += acceleration_noise
        window[:, 3:] += gyro_noise
    count = int(rng.integers(0, int(np.floor(0.1 * WINDOW_SAMPLES)) + 1))
    dropped = rng.choice(WINDOW_SAMPLES, size=count, replace=False)
    if omitted != "drop" and count:
        retained = np.ones(WINDOW_SAMPLES, dtype=bool)
        retained[dropped] = False
        grid = np.arange(WINDOW_SAMPLES)
        window = np.column_stack([
            np.interp(grid, grid[retained], window[retained, index]) for index in range(6)
        ])
    return window


def donor_pools(sessions, allowed):
    """Pool da sessioni ammesse, mai da una sessione tenuta fuori."""
    walking, falls = [], []
    for session in sessions:
        if session["id"] not in allowed:
            continue
        values = session["values"]
        for center in range(CONTEXT_RADIUS, len(values) - CONTEXT_RADIUS, FS):
            start = (center - CONTEXT_RADIUS) / FS
            stop = (center + CONTEXT_RADIUS) / FS
            if any(start <= end + 1 and stop >= begin - 1
                   for begin, end in session["intervals"]):
                continue
            context = get_window(values, center, CONTEXT_RADIUS)
            norm = np.linalg.norm(context[:, :3], axis=1)
            pre = context[:FS, :3].mean(axis=0)
            post = context[-FS:, :3].mean(axis=0)
            cosine = np.dot(pre, post) / (np.linalg.norm(pre) * np.linalg.norm(post))
            if norm.max() >= 15 or norm.min() <= 0.6 * G or cosine < np.cos(np.deg2rad(15)):
                continue
            walking.append((session["id"], context))
        for segment in session["segments"]:
            impact = segment["impact"]
            falls.append((session["id"], get_window(values, impact, CONTEXT_RADIUS)))
    if not walking or len({source for source, _ in falls}) < 3:
        raise ValueError("Pool training insufficiente: servono tratti non-falling e 3 sessioni con caduta")
    return walking, falls


def align_gravity(segment, target):
    source = segment[-FS:, :3].mean(axis=0)
    if min(np.linalg.norm(source), np.linalg.norm(target)) < 1e-8:
        raise ValueError("Gravita nulla durante allineamento post")
    rotation, _ = Rotation.align_vectors(
        (target / np.linalg.norm(target))[None, :],
        (source / np.linalg.norm(source))[None, :],
    )
    result = segment.copy()
    result[:, :3] = rotation.apply(result[:, :3])
    result[:, 3:] = rotation.apply(result[:, 3:])
    return result


def recombine_fall(source_id, context, walking, falls, rng):
    pre_options = [(sid, values) for sid, values in walking if sid != source_id]
    if not pre_options:
        raise ValueError("Nessuna sessione diversa disponibile per il pre")
    pre_id, pre = pre_options[int(rng.integers(len(pre_options)))]
    post_options = [(sid, values) for sid, values in falls if sid not in (source_id, pre_id)]
    if not post_options:
        raise ValueError("Nessuna terza sessione disponibile per il post")
    post_id, post = post_options[int(rng.integers(len(post_options)))]
    # Crossfade di 9 intervalli = 0.3 s, centrati ai confini +/-1 s.
    left, right = CONTEXT_RADIUS - FS, CONTEXT_RADIUS + FS
    post_segment = align_gravity(post[right:], context[right - 8:right + 1, :3].mean(axis=0))
    aligned_post = np.repeat(post_segment[:1], len(context), axis=0)
    aligned_post[right:] = post_segment
    crossfade_samples = int(round(0.3 * FS))
    grid = np.arange(len(context))
    pre_to_fall = np.clip((grid - (left - crossfade_samples // 2)) / crossfade_samples, 0, 1)
    fall_to_post = np.clip((grid - (right - crossfade_samples // 2)) / crossfade_samples, 0, 1)
    combined = pre * (1 - pre_to_fall[:, None]) + context * pre_to_fall[:, None]
    combined = combined * (1 - fall_to_post[:, None]) + aligned_post * fall_to_post[:, None]
    return combined, (pre_id, source_id, post_id)


def hard_negative(kind, walking, falls, rng):
    walk_id, context = walking[int(rng.integers(len(walking)))]
    # Gravita costante: nessun cambio sistematico di inclinazione.
    gravity = sosfiltfilt(GRAVITY_FILTER, context[:, :3], axis=0)
    baseline = gravity.mean(axis=0)
    direction = baseline / np.linalg.norm(baseline)
    result = context.copy()
    result[:, :3] = baseline + context[:, :3] - gravity
    norm = np.linalg.norm(result[:, :3], axis=1)
    if norm.max() >= 15 or norm.min() <= 0.6 * G:
        # Limita solo la dinamica per mantenere il negativo gyro senza picchi.
        dynamic = result[:, :3] - baseline
        limit = min(15 - np.linalg.norm(baseline), np.linalg.norm(baseline) - 0.6 * G)
        if limit <= 0:
            raise ValueError("Baseline non-falling fuori dalle soglie candidate")
        result[:, :3] = baseline + dynamic * min(1.0, 0.95 * limit / np.linalg.norm(dynamic, axis=1).max())
    if kind == "negative_gyro":
        result[:, 3:] *= rng.uniform(1.5, 2.0)
        return result, (walk_id,)
    impact_options = [(sid, values) for sid, values in falls
                      if np.linalg.norm(values[CONTEXT_RADIUS, :3]) > 15]
    if not impact_options:
        raise ValueError("Nessuna caduta con urto >15 disponibile per il negativo sintetico")
    fall_id, fall = impact_options[int(rng.integers(len(impact_options)))]
    fall_norm = np.linalg.norm(fall[:, :3], axis=1)
    center = CONTEXT_RADIUS
    pulse = np.zeros(len(context))
    region = slice(center - 4, center + 5)
    pulse[region] = np.maximum(0, fall_norm[region] - G) * np.hanning(9)
    result[:, :3] += pulse[:, None] * direction
    return result, (walk_id, fall_id)


def training_data(real, sessions, indices, seed, omitted=None, post_samples=45):
    """Restituisce reali e sintetici SEPARATI; ogni sintetico ha provenienza."""
    originals = {
        "features": real["features"][indices].copy(),
        "windows": real["contexts"][indices, 15:61 + post_samples].copy(),
        "labels": real["labels"][indices].copy(),
        "origin": np.full(len(indices), "real"),
        "technique": np.full(len(indices), "original"),
        "parent_index": np.asarray(indices).copy(),
        "donors": [(str(real["groups"][i]),) for i in indices],
        "sample_weight": np.ones(len(indices)),
    }
    allowed = set(real["groups"][indices])
    walking, falls = donor_pools(sessions, allowed)
    synthetic = {key: [] for key in originals}
    for index in indices:
        positive = bool(real["labels"][index])
        for copy in range(30 if positive else 3):
            # Stream distinti: un'ablazione non cambia le estrazioni casuali
            # delle altre copie ne delle trasformazioni rimaste attive.
            rng = np.random.default_rng(np.random.SeedSequence([seed, int(index), copy, 0]))
            transform_rng = np.random.default_rng(np.random.SeedSequence([seed, int(index), copy, 1]))
            context = real["contexts"][index].copy()
            donors = (str(real["groups"][index]),)
            kind = "transformation"
            if positive and copy >= 15 and omitted != "recombination":
                kind = "recombination"
                source_session = next(session for session in sessions if session["id"] == donors[0])
                event = int(real["event_ids"][index].rsplit(":", 1)[1])
                context = get_window(
                    source_session["values"], source_session["segments"][event]["impact"], CONTEXT_RADIUS,
                )
                context, donors = recombine_fall(donors[0], context, walking, falls, rng)
            if not positive and copy in (1, 2):
                requested = "negative_impact" if copy == 1 else "negative_gyro"
                if omitted != requested:
                    kind = requested
                    context, donors = hard_negative(kind, walking, falls, rng)
            mirrored = positive and copy % 2 == 0 and omitted != "mirror"
            gravity = sosfiltfilt(GRAVITY_FILTER, context[:, :3], axis=0)
            window = augment_window(context, gravity, transform_rng, omitted, mirrored)
            if kind == "negative_gyro":
                # Mantiene "senza picco" anche dopo scala, warp e rumore.
                norm = np.linalg.norm(window[:, :3], axis=1)
                bounded = np.clip(norm, 0.6 * G + 0.01, 15 - 0.01)
                window[:, :3] *= (bounded / norm)[:, None]
            window = window[:RADIUS + post_samples + 1]
            if not set(donors).issubset(allowed):
                raise RuntimeError("Donatore esterno al training")
            synthetic["windows"].append(window)
            synthetic["features"].append(list(extract_features(window).values()))
            synthetic["labels"].append(int(positive))
            synthetic["origin"].append("synthetic")
            synthetic["technique"].append(kind + ("+mirror" if mirrored else ""))
            synthetic["parent_index"].append(int(index))
            synthetic["donors"].append(donors)
            synthetic["sample_weight"].append(0.4)
    for key in synthetic:
        if key != "donors":
            synthetic[key] = np.asarray(synthetic[key])
    return originals, synthetic


def fit_model(features, labels, sample_weight=None, balance_classes=True, n_estimators=100):
    positives = np.count_nonzero(labels == 1)
    negatives = np.count_nonzero(labels == 0)
    if not positives or not negatives:
        raise ValueError("Training fold privo di una classe; LOSO non valido")
    model = XGBClassifier(
        max_depth=3, n_estimators=n_estimators, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8,
        scale_pos_weight=negatives / positives if balance_classes else 1,
        random_state=SEED, n_jobs=1, objective="binary:logistic",
        eval_metric="logloss", tree_method="hist",
        base_score=0.5,
    )
    model.fit(features, labels, sample_weight=sample_weight)
    return model


def validate(real, sessions, augmented=True, omitted=None, only_synthetic=False, output_dir=None):
    features, labels, groups = real["features"], real["labels"], real["groups"]
    session_ids = np.unique(groups)
    if len(session_ids) < 2:
        raise ValueError("Servono almeno due sessioni per leave-one-session-out")
    splitter = GroupKFold(n_splits=len(session_ids))
    probabilities = np.full(len(labels), np.nan)
    importances = np.zeros(features.shape[1])
    if output_dir is not None:
        output_dir.mkdir(parents=True, exist_ok=True)
    for fold, (train, test) in enumerate(splitter.split(features, labels, groups), start=1):
        if set(groups[train]).intersection(groups[test]) or len(np.unique(groups[test])) != 1:
            raise RuntimeError("Contaminazione o fold non leave-one-session-out")
        if augmented:
            originals, synthetic = training_data(real, sessions, train, SEED + fold, omitted)
            parts = [synthetic] if only_synthetic else [originals, synthetic]
            x_train = np.vstack([part["features"] for part in parts])
            y_train = np.concatenate([part["labels"] for part in parts])
            weights = np.concatenate([part["sample_weight"] for part in parts])
            if any(set(donors).intersection(groups[test]) for donors in synthetic["donors"]):
                raise RuntimeError("Sessione test usata nella generazione")
        else:
            x_train, y_train = features[train], labels[train]
            weights = np.ones(len(train))
        model = fit_model(x_train, y_train, weights)
        if output_dir is not None:
            model.save_model(output_dir / f"test_{groups[test][0]}.json")
        probabilities[test] = model.predict_proba(features[test])[:, 1]
        importances += model.feature_importances_ / len(session_ids)
        print(
            f"  {'solo sintetici' if only_synthetic else ('con' if augmented else 'senza')} augmentation"
            f"{' senza ' + omitted if omitted else ''}, "
            f"fold {fold}/{len(session_ids)}: test={groups[test][0]}, "
            f"training={len(y_train)} ({int(y_train.sum())} positivi), "
            f"test originali={len(test)}; "
            f"reali training={0 if only_synthetic else len(train)}, "
            f"sintetici training={len(synthetic['labels']) if augmented else 0}",
            flush=True,
        )
    if not np.isfinite(probabilities).all():
        raise RuntimeError("Predizioni out-of-fold mancanti o non finite")
    return probabilities, importances


def origin_validation(real, sessions, output_dir=None):
    """Train/test senza alcuna sessione donatrice condivisa, prima di generare."""
    identifiers = np.unique(real["groups"])
    predictions, targets, fall_labels = [], [], []
    if output_dir is not None:
        output_dir.mkdir(parents=True, exist_ok=True)
    # Due partizioni mantengono pool di camminata e cadute su entrambi i lati.
    splitter = GroupKFold(n_splits=2)
    for fold, (train_sessions, test_sessions) in enumerate(
        splitter.split(identifiers, groups=identifiers), start=1,
    ):
        train_ids, test_ids = identifiers[train_sessions], identifiers[test_sessions]
        train = np.flatnonzero(np.isin(real["groups"], train_ids))
        test = np.flatnonzero(np.isin(real["groups"], test_ids))
        train_parts = training_data(real, sessions, train, SEED + fold)
        test_parts = training_data(real, sessions, test, SEED + 100 + fold)
        train_donors = {sid for part in train_parts for donors in part["donors"] for sid in donors}
        test_donors = {sid for part in test_parts for donors in part["donors"] for sid in donors}
        if train_donors.intersection(test_donors):
            raise RuntimeError("Donatori condivisi nella validazione reale/sintetico")
        x_train = np.vstack([part["features"] for part in train_parts])
        y_train = np.r_[np.zeros(len(train)), np.ones(len(train_parts[1]["labels"]))]
        # Bilanciamento per origine E classe caduta: impedisce che 30/3 copie
        # rendano la classe caduta una scorciatoia per riconoscere l'origine.
        classes = np.concatenate([part["labels"] for part in train_parts])
        weights = np.empty(len(y_train))
        for origin in (0, 1):
            for label in (0, 1):
                mask = (y_train == origin) & (classes == label)
                if mask.any():
                    weights[mask] = len(y_train) / (4 * mask.sum())
        classifier = fit_model(x_train, y_train, weights, balance_classes=False)
        if output_dir is not None:
            classifier.save_model(output_dir / f"fold_{fold:02d}.json")
        x_test = np.vstack([part["features"] for part in test_parts])
        targets.extend([0] * len(test) + [1] * len(test_parts[1]["labels"]))
        fall_labels.extend(np.concatenate([part["labels"] for part in test_parts]))
        predictions.extend(classifier.predict_proba(x_test)[:, 1])
        print(
            f"  Origine fold {fold}/2: {len(train_ids)} sessioni train, "
            f"{len(test_ids)} test; donatori disgiunti, sintetici test solo per questo audit.",
            flush=True,
        )
    targets = np.asarray(targets)
    fall_labels = np.asarray(fall_labels)
    predictions = np.asarray(predictions)
    evaluation_weights = np.empty(len(targets))
    for origin in (0, 1):
        for label in (0, 1):
            mask = (targets == origin) & (fall_labels == label)
            evaluation_weights[mask] = 1 / mask.sum()
    score = roc_auc_score(targets, predictions, sample_weight=evaluation_weights)
    print(f"AUC ROC reale(0) vs sintetico(1), bilanciata per classe caduta: {score:.4f}")
    for label in (0, 1):
        mask = fall_labels == label
        print(f"  Classe caduta={label}: AUC origine={roc_auc_score(targets[mask], predictions[mask]):.4f}")
    print("AUC vicina a 0.5: origini poco distinguibili; alta: artefatti/distribution shift.")
    return float(score)


def report(sessions, labels, groups, event_ids, probabilities, importances, names, augmented):
    total_falls = sum(len(session["impacts"]) for session in sessions)
    nonfall_minutes = sum(session["nonfall_seconds"] for session in sessions) / 60
    if nonfall_minutes <= 0:
        raise ValueError("Nessuna durata senza caduta per calcolare FA/min")
    max_negative = float(probabilities[labels == 0].max())
    # XGBoost restituisce float32: un epsilon float64 sparirebbe in inferenza.
    threshold = float(np.nextafter(np.float32(max_negative), np.float32(np.inf)))
    precision, recall, _ = precision_recall_curve(labels, probabilities)
    pr_auc = float(auc(recall, precision))
    print(f"\n=== {'CON' if augmented else 'SENZA'} AUGMENTATION: predizioni LOSO ===")
    print(f"PR-AUC (trapezi, candidati): {pr_auc:.4f}")
    print(f"Average precision (candidati): {average_precision_score(labels, probabilities):.4f}")
    print(f"Durata senza caduta: {nonfall_minutes:.3f} min (tutte le sessioni)")
    results = {"pr_auc": pr_auc, "threshold": threshold}
    for title, cutoff in (("0.5", 0.5), ("zero FA OOF", threshold)):
        predicted = probabilities >= cutoff
        detected = len(set(event_ids[predicted & (labels == 1)]))
        false_alarms = int(np.count_nonzero(predicted & (labels == 0)))
        rate = false_alarms / nonfall_minutes
        print(
            f"Soglia {title} ({cutoff:.17g}): cadute trovate {detected}/{total_falls}; "
            f"falsi allarmi {false_alarms}; FA/min={rate:.4f}"
        )
        results[title] = (detected, false_alarms, rate)
    print("Soglia zero FA selezionata sugli stessi OOF: nessuna garanzia su nuovi dati.")
    print("FA/min: durata fuori falling, incluse le fasce di esclusione +/-1 s.")
    print("Probabilita massima per sessione, sui soli candidati etichettati originali:")
    print(f"{'sessione':32s}  {'caduta':7s}  {'probabilita massima':>20s}")
    for session in sessions:
        selected = probabilities[groups == session["id"]]
        maximum = f"{selected.max():.6f}" if selected.size else "n/d: nessun candidato"
        print(f"{session['id']:32s}  {'si' if session['impacts'] else 'no':7s}  {maximum:>20s}")
    print("Top 15 feature importance (gain normalizzato, media dei fold):")
    for index in np.argsort(-importances, kind="stable")[:15]:
        print(f"  {names[index]:30s} {importances[index]:.5f}")
    print(flush=True)
    return results


def mobile_metrics(labels, event_ids, probabilities, sessions):
    precision, recall, _ = precision_recall_curve(labels, probabilities)
    predicted = probabilities >= 0.5
    negatives = (labels == 0)
    false_alarms = int(np.count_nonzero(predicted & negatives))
    return {
        "falls_found": len(set(event_ids[predicted & (labels == 1)])),
        "falls_total": sum(len(session["impacts"]) for session in sessions),
        "false_alarms": false_alarms,
        "false_alarms_per_minute": false_alarms / (
            sum(session["nonfall_seconds"] for session in sessions) / 60
        ),
        "pr_auc": float(auc(recall, precision)),
        "threshold": 0.5,
        "zero_fa_threshold_oof": float(np.nextafter(
            np.float32(probabilities[negatives].max()), np.float32(np.inf),
        )),
    }


def select_top_features(model, count=25):
    # Tie-break per indice originale; ordine finale stabile per l'app.
    ranked = np.argsort(-model.feature_importances_, kind="stable")[:count]
    return np.sort(ranked)


def benchmark_mobile(model, windows, names):
    rng = np.random.default_rng(SEED)
    indices = rng.integers(0, len(windows), size=1000)
    for index in indices[:30]:
        features = list(extract_features(windows[index], names).values())
        model.predict_proba(np.asarray([features]))
    feature_times, predict_times = [], []
    for index in indices:
        start = time.perf_counter_ns()
        features = list(extract_features(windows[index], names).values())
        middle = time.perf_counter_ns()
        model.predict_proba(np.asarray([features]))
        stop = time.perf_counter_ns()
        feature_times.append((middle - start) / 1e6)
        predict_times.append((stop - middle) / 1e6)
    combined = np.asarray(feature_times) + np.asarray(predict_times)
    return {
        "iterations": 1000, "source": "real resampled windows, repeated with seed 42",
        "feature_mean_ms": float(np.mean(feature_times)),
        "predict_mean_ms": float(np.mean(predict_times)),
        "combined_mean_ms": float(combined.mean()),
        "combined_median_ms": float(np.median(combined)),
        "combined_p95_ms": float(np.percentile(combined, 95)),
        "booster_json_kib": len(model.get_booster().save_raw(raw_format="json")) / 1024,
        "platform": "Python host, not a phone measurement",
    }


def kotlin_export(model, feature_matrix, names, threshold):
    """m2cgen Java -> Kotlin; verifica tutte le forme sintattiche convertite."""
    import m2cgen

    java = m2cgen.export_to_java(model, class_name="FallModel")
    # XGBoost confronta Float32; il dump JSON tronca le cifre decimali.
    java = re.sub(
        r"(input\[\d+\]\s*(?:<|>=)\s*)([-+0-9.eE]+)",
        lambda match: match[1] + repr(float(np.float32(match[2]))), java,
    )
    kotlin = java.replace("public class FallModel {", "object FallModel {")
    kotlin = kotlin.replace(
        "public static double[] score(double[] input) {",
        "private fun score(input: DoubleArray): DoubleArray {",
    ).replace(
        "private static double sigmoid(double x) {",
        "private fun sigmoid(x: Double): Double {",
    )
    kotlin = re.sub(r"double (var\d+);", r"var \1: Double", kotlin)
    kotlin = re.sub(r"double (\w+) =", r"val \1 =", kotlin)
    kotlin = re.sub(r"new double\[\] \{([^}]+)\}", r"doubleArrayOf(\1)", kotlin)
    kotlin = kotlin.replace("Math.exp", "kotlin.math.exp").replace(";", "")
    if re.search(r"\b(?:public|private static|double|new)\b", kotlin):
        raise ValueError("Sintassi m2cgen Java non supportata: export Kotlin interrotto")
    api = (
        f"    const val THRESHOLD: Double = {threshold!r}\n"
        "    val FEATURE_NAMES: List<String> = listOf("
        + ", ".join(json.dumps(name) for name in names) + ")\n"
        "    fun predictProbability(features: DoubleArray): Double {\n"
        f"        require(features.size == {len(names)} && features.all {{ it.isFinite() }})\n"
        "        val input = DoubleArray(features.size) { features[it].toFloat().toDouble() }\n"
        "        require(input.all { it.isFinite() })\n"
        "        return score(input)[1]\n"
        "    }\n"
    )
    kotlin = kotlin.replace("object FallModel {", "object FallModel {\n" + api, 1)
    # Verifica indipendente delle espressioni prodotte da m2cgen, prima del compilatore.
    namespace = {}
    python_source = re.sub(
        r"(input\[\d+\]\s*(?:<|>=)\s*)([-+0-9.eE]+)",
        lambda match: match[1] + repr(float(np.float32(match[2]))),
        m2cgen.export_to_python(model),
    )
    exec(python_source, namespace)
    expected = model.predict_proba(feature_matrix)[:, 1]
    actual = np.asarray([
        namespace["score"](row.astype(np.float32).astype(float).tolist())[1]
        for row in feature_matrix
    ])
    np.testing.assert_allclose(actual, expected, rtol=0, atol=2e-6)
    header = (
        "// Generated by train_fall.py using m2cgen Java expressions converted to Kotlin.\n"
        "// Input: selected feature vector, exact order/formulas in features.json.\n"
        "// score returns [P(non-fall), P(fall)]; no augmentation or sensor preprocessing.\n"
    )
    return header + kotlin


def verify_kotlin(source, model, matrix, compiler):
    """Compila in una cartella temporanea, nessun file JVM nel progetto."""
    rng = np.random.default_rng(SEED)
    random_rows = rng.uniform(matrix.min(axis=0), matrix.max(axis=0), size=(1000, matrix.shape[1]))
    boundary_rows = []
    nodes = [json.loads(tree) for tree in model.get_booster().get_dump(dump_format="json")]
    boundaries = set()
    while nodes:
        node = nodes.pop()
        if "leaf" in node:
            continue
        boundaries.add((int(node["split"].removeprefix("f")), float(np.float32(node["split_condition"]))))
        nodes.extend(node["children"])
    for column, value in sorted(boundaries):
        for boundary in (
            np.nextafter(np.float32(value), np.float32(-np.inf)),
            np.float32(value), np.nextafter(np.float32(value), np.float32(np.inf)),
        ):
            row = matrix[0].copy()
            row[column] = boundary
            boundary_rows.append(row)
    matrix = np.vstack((matrix, random_rows, np.asarray(boundary_rows)))
    expected = model.predict_proba(matrix)[:, 1]
    runner = (
        "fun main() {\n"
        "generateSequence(::readLine).forEach { line ->\n"
        "val row = line.split(' ').map { it.toDouble() }.toDoubleArray()\n"
        "println(FallModel.predictProbability(row))\n}\n}\n"
    )
    serialized = "\n".join(" ".join(repr(float(value)) for value in row) for row in matrix) + "\n"
    with tempfile.TemporaryDirectory(prefix="fall-kotlin-") as directory:
        directory = Path(directory)
        (directory / "FallModel.kt").write_text(source, encoding="utf-8")
        (directory / "Main.kt").write_text(runner, encoding="utf-8")
        subprocess.run(
            [str(compiler), str(directory / "FallModel.kt"), str(directory / "Main.kt"),
             "-include-runtime", "-d", str(directory / "test.jar")],
            check=True, capture_output=True, text=True,
        )
        result = subprocess.run(
            ["java", "-jar", str(directory / "test.jar")],
            check=True, capture_output=True, text=True, input=serialized,
        )
    actual = np.asarray([float(line) for line in result.stdout.splitlines()])
    np.testing.assert_allclose(actual, expected, atol=2e-6, rtol=0)
    return {"compiled": True, "cases": len(matrix),
            "max_probability_abs_error": float(np.abs(actual - expected).max()),
            "probability_abs_tolerance": 2e-6}


def optimize_mobile(sessions, output_dir, kotlin_compiler=None):
    features, contexts, labels, groups, event_ids, names = make_dataset(sessions)
    base = dict(features=features, contexts=contexts, labels=labels, groups=groups,
                event_ids=event_ids, feature_names=names)
    results, final_models = {}, {}
    print("\nMobile: depth=3, 100 alberi; top25 selezionate SOLO sul training di ogni fold.")
    for post_samples in (45, 30):
        windows = contexts[:, 15:61 + post_samples]
        real = {**base, "features": np.asarray([
            list(extract_features(window).values()) for window in windows
        ])}
        probabilities = {count: np.full(len(labels), np.nan) for count in (38, 25)}
        splitter = GroupKFold(n_splits=len(np.unique(groups)))
        for fold, (train, test) in enumerate(splitter.split(features, labels, groups), start=1):
            originals, synthetic = training_data(
                real, sessions, train, SEED + fold, post_samples=post_samples,
            )
            if any(set(donors).intersection(groups[test]) for donors in synthetic["donors"]):
                raise RuntimeError("Contaminazione training/test nella pipeline mobile")
            x = np.vstack((originals["features"], synthetic["features"]))
            y = np.r_[originals["labels"], synthetic["labels"]]
            weights = np.r_[originals["sample_weight"], synthetic["sample_weight"]]
            full = fit_model(x, y, weights)
            selected = select_top_features(full)
            reduced = fit_model(x[:, selected], y, weights)
            probabilities[38][test] = full.predict_proba(real["features"][test])[:, 1]
            probabilities[25][test] = reduced.predict_proba(real["features"][test][:, selected])[:, 1]
            print(f"  post={post_samples / FS:.1f}s, fold {fold}/17, "
                  f"test={groups[test][0]}, selezione25 solo training", flush=True)
        originals, synthetic = training_data(
            real, sessions, np.arange(len(labels)), SEED, post_samples=post_samples,
        )
        x = np.vstack((originals["features"], synthetic["features"]))
        y = np.r_[originals["labels"], synthetic["labels"]]
        weights = np.r_[originals["sample_weight"], synthetic["sample_weight"]]
        full = fit_model(x, y, weights)
        selected = select_top_features(full)
        reduced = fit_model(x[:, selected], y, weights)
        for count, model, columns in (
            (38, full, np.arange(len(names))), (25, reduced, selected),
        ):
            if not np.isfinite(probabilities[count]).all():
                raise RuntimeError("Predizioni LOSO mancanti")
            metrics = mobile_metrics(labels, event_ids, probabilities[count], sessions)
            selected_names = [names[index] for index in columns]
            benchmark = benchmark_mobile(model, windows, selected_names)
            metrics.update(benchmark)
            metrics["post_seconds"] = post_samples / FS
            metrics["features"] = count
            metrics["window_plus_compute_ms"] = post_samples / FS * 1000 + benchmark["combined_mean_ms"]
            key = f"post_{post_samples / FS:.1f}s_features_{count}"
            results[key] = metrics
            final_models[(post_samples, count)] = (model, columns, windows, x[:, columns])

    print("\n=== MOBILE LOSO, soglia 0.5 ===")
    print("post | feature | cadute | FA/min | PR-AUC | estrazione+predict ms | finestra+calcolo ms | booster JSON KiB")
    for result in results.values():
        print(
            f"{result['post_seconds']:.1f}s | {result['features']:7d} | "
            f"{result['falls_found']}/{result['falls_total']} | "
            f"{result['false_alarms_per_minute']:.4f} | {result['pr_auc']:.4f} | "
            f"{result['combined_mean_ms']:.4f} | {result['window_plus_compute_ms']:.4f} | "
            f"{result['booster_json_kib']:.2f}"
        )
    print(
        "Latenza finestra+calcolo: dall'impatto GIA LOCALIZZATO, benchmark Python host. "
        "NON e latenza end-to-end del telefono: NMS globale dei candidati e "
        "ricentraggio offline +/-3s non sono causali; la latenza del detector "
        "streaming non e misurata e va aggiunta. Nessun campione oltre il post "
        "scelto viene usato da extract_features."
    )

    model, selected, windows, verification_matrix = final_models[(30, 25)]
    selected_names = [names[index] for index in selected]
    rng = np.random.default_rng(SEED)
    if np.count_nonzero(labels) < 10 or np.count_nonzero(labels == 0) < 10:
        raise ValueError("Servono almeno 10 finestre reali per classe per i golden test")
    chosen = np.r_[
        rng.choice(np.flatnonzero(labels == 1), size=10, replace=False),
        rng.choice(np.flatnonzero(labels == 0), size=10, replace=False),
    ]
    golden_cases = []
    for index in chosen:
        expected = list(extract_features(windows[index], selected_names).values())
        golden_cases.append({
            "session_id": str(groups[index]), "dataset_index": int(index),
            "label": int(labels[index]), "origin": "real_resampled_no_augmentation",
            "raw_window": windows[index].tolist(), "expected_features": expected,
            "expected_probability": float(model.predict_proba(np.asarray([expected]))[0, 1]),
        })
    chosen_metrics = results["post_1.0s_features_25"]
    threshold = chosen_metrics["zero_fa_threshold_oof"]
    kotlin = kotlin_export(model, verification_matrix, selected_names, threshold)
    kotlin_validation = {"compiled": False, "reason": "Pass --kotlin-compiler to verify actual Kotlin"}
    if kotlin_compiler is not None:
        kotlin_validation = verify_kotlin(kotlin, model, verification_matrix, kotlin_compiler)
        print("Verifica Kotlin compilato:", kotlin_validation)
    else:
        print("ATTENZIONE: Kotlin non compilato; verificate solo le espressioni m2cgen in Python.")
    definitions = {item["name"]: item for item in feature_definitions()}
    metadata = {
        "schema_version": 2, "model": "fall_model.json", "kotlin_model": "fall_model.kt",
        "feature_names": selected_names,
        "features": [{"index": index, **definitions[name]} for index, name in enumerate(selected_names)],
        "all_feature_definitions": feature_definitions(),
        "sampling_rate_hz": FS, "window_samples": 76, "peak_index": RADIUS,
        "pre_seconds": 1.5, "post_seconds": 1.0, "window_columns": SENSOR_COLUMNS,
        "segments": {"pre": "[0:45] = [-1.5,0) s; 45 samples",
                     "post": "[45:76] = [0,1.0] s; 31 samples, includes impact",
                     "pre_gravity": "[15:45], 30 samples",
                     "post_gravity_and_immobility": "[-30:], 30 samples; (0,1.0] s"},
        "notation": {
            "a": "sqrt(ax^2+ay^2+az^2); includes gravity",
            "omega": "sqrt(gx^2+gy^2+gz^2)",
            "mean": "sum(x)/N", "std": "sqrt(sum((x-mean(x))^2)/N); ddof=0",
            "angle(u,v)": "acos(clamp(dot(u,v)/(norm(u)*norm(v)),-1,1))*180/pi",
            "argmin_argmax": "first occurrence in chronological order",
            "axes": "X lateral, +Y upright vertical, Z forward/back",
        },
        "preprocessing": {
            "resampling": "linear at 30 Hz; integer timestamp_ns subtraction before /1e9",
            "missing_sensor_values": "linear interpolation; edge replication",
            "window_edges": "first/last sample replicated",
            "candidates": "local maxima |a|>15 or local minima |a|<0.6g; global NMS 1s by abs(|a|-g)",
            "centering": "training positives: offline segment_fall +/-3s argmax; inference: supplied candidate",
            "finite_inputs_only": True, "gravity_angles": "raise if mean norm <1e-8",
        },
        "threshold": threshold, "threshold_comparison": ">=",
        "threshold_source": "next Float32 above max negative OOF probability, selected on same validation data; not independent",
        "evaluation_threshold": 0.5, "seed": SEED,
        "model_parameters": {"max_depth": 3, "n_estimators": 100, "base_score": 0.5},
        "feature_selection": "gain top25 per training fold, stable original order; final selection on all training data",
        "comparison_loso": results, "kotlin_validation": kotlin_validation,
        "probability_tolerance_abs": 2e-6, "feature_tolerance_abs": 1e-8,
        "feature_tolerance_rel": 1e-8,
        "latency_caveat": "window_plus_compute_ms assumes an already localized impact; offline NMS/recentering lookahead excluded; not measured phone end-to-end latency",
        "legacy_models": "Existing UBJ and fold models NOT updated; incompatible with this 25-feature contract",
    }
    golden = {
        "purpose": "Numeric regression only; final model saw these real sessions during training, not a held-out performance test",
        "feature_names": selected_names, "window_columns": SENSOR_COLUMNS,
        "sampling_rate_hz": FS, "window_samples": 76, "peak_index": RADIUS,
        "feature_tolerance_abs": 1e-8, "feature_tolerance_rel": 1e-8,
        "probability_tolerance_abs": 2e-6, "cases": golden_cases,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    model.save_model(output_dir / "fall_model.json")
    (output_dir / "fall_model.kt").write_text(kotlin, encoding="utf-8")
    metadata["exported_model_json_kib"] = (output_dir / "fall_model.json").stat().st_size / 1024
    metadata["exported_model_kotlin_source_kib"] = (output_dir / "fall_model.kt").stat().st_size / 1024
    for filename, payload in (("features.json", metadata), ("golden_tests.json", golden)):
        (output_dir / filename).write_text(
            json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8",
        )
    restored = XGBClassifier()
    restored.load_model(output_dir / "fall_model.json")
    np.testing.assert_array_equal(
        restored.predict_proba(verification_matrix), model.predict_proba(verification_matrix),
    )
    for case in golden_cases:
        actual = list(extract_features(case["raw_window"], selected_names).values())
        np.testing.assert_allclose(actual, case["expected_features"], atol=1e-8, rtol=1e-8)
    print(f"\nEsportati solo fall_model.kt, fall_model.json, features.json, golden_tests.json in {output_dir}")
    print(f"Dimensione file finale: JSON {(output_dir / 'fall_model.json').stat().st_size / 1024:.2f} KiB; "
          f"Kotlin {(output_dir / 'fall_model.kt').stat().st_size / 1024:.2f} KiB (sorgente, non binario compilato).")
    print("Golden test: 10 cadute + 10 negativi reali, 76x6 campioni per finestra, feature e probabilita attese.")


def classification_metrics(labels, event_ids, probabilities, sessions, threshold):
    predicted = probabilities >= threshold
    tn, fp, fn, tp = confusion_matrix(labels, predicted, labels=[0, 1]).ravel()
    precision, recall, _ = precision_recall_curve(labels, probabilities)
    total_events = sum(len(session["impacts"]) for session in sessions)
    found = len(set(event_ids[predicted & (labels == 1)]))
    return {
        "threshold": float(threshold),
        "tp": int(tp), "fp": int(fp), "tn": int(tn), "fn": int(fn),
        "accuracy": float(accuracy_score(labels, predicted)),
        "precision": float(precision_score(labels, predicted, zero_division=0)),
        "recall_candidates": float(recall_score(labels, predicted)),
        "specificity": float(tn / (tn + fp)),
        "f1": float(f1_score(labels, predicted, zero_division=0)),
        "balanced_accuracy": float(balanced_accuracy_score(labels, predicted)),
        "mcc": float(matthews_corrcoef(labels, predicted)),
        "roc_auc": float(roc_auc_score(labels, probabilities)),
        "pr_auc": float(auc(recall, precision)),
        "average_precision": float(average_precision_score(labels, probabilities)),
        "falls_found": found, "falls_total": total_events,
        "recall_events": found / total_events,
        "false_alarms_per_minute": int(fp) / (
            sum(session["nonfall_seconds"] for session in sessions) / 60
        ),
    }


def compare_models(sessions, output_dir):
    """Confronto riproducibile; report unico con risultati e predizioni verificabili."""
    features, contexts, labels, groups, event_ids, names = make_dataset(sessions)
    models_dir = output_dir / "comparison"
    models_dir.mkdir(parents=True, exist_ok=True)
    all_results = {}
    comparison_start = time.perf_counter()
    for label, post, count, trees in (("completo", 45, 38, 200), ("leggero", 30, 25, 100)):
        windows = contexts[:, 15:61 + post]
        real = {
            "features": np.asarray([list(extract_features(window).values()) for window in windows]),
            "contexts": contexts, "labels": labels, "groups": groups,
            "event_ids": event_ids, "feature_names": names,
        }
        predictions = np.full(len(labels), np.nan)
        fold_details = []
        fold_sizes = []
        splitter = GroupKFold(n_splits=len(np.unique(groups)))
        for fold, (train, test) in enumerate(splitter.split(features, labels, groups), start=1):
            start = time.perf_counter()
            originals, synthetic = training_data(
                real, sessions, train, SEED + fold, post_samples=post,
            )
            if set(groups[train]).intersection(groups[test]) or any(
                set(donors).intersection(groups[test]) for donors in synthetic["donors"]
            ):
                raise RuntimeError("Contaminazione training/test nel confronto")
            x = np.vstack((originals["features"], synthetic["features"]))
            y = np.r_[originals["labels"], synthetic["labels"]]
            weights = np.r_[originals["sample_weight"], synthetic["sample_weight"]]
            prepared = time.perf_counter()
            baseline = fit_model(x, y, weights, n_estimators=trees)
            baseline_end = time.perf_counter()
            columns = np.arange(len(names))
            model = baseline
            if count == 25:
                columns = select_top_features(baseline)
                model = fit_model(x[:, columns], y, weights, n_estimators=trees)
            fit_end = time.perf_counter()
            predictions[test] = model.predict_proba(real["features"][test][:, columns])[:, 1]
            fold_details.append({
                "test_session": str(groups[test][0]),
                "augmentation_and_matrix_s": prepared - start,
                "baseline_fit_s": baseline_end - prepared,
                "selection_and_refit_s": fit_end - baseline_end,
                "total_training_s": fit_end - start,
                "selected_features": [names[index] for index in columns],
            })
            fold_sizes.append(len(y))
            print(f"{label}: fold {fold}/{len(np.unique(groups))}, test={groups[test][0]}, "
                  f"training={len(y)}, tempo={fit_end - start:.3f}s", flush=True)
        if not np.isfinite(predictions).all():
            raise RuntimeError("Predizioni OOF mancanti")
        # Training finale separato dalla valutazione OOF.
        start = time.perf_counter()
        originals, synthetic = training_data(
            real, sessions, np.arange(len(labels)), SEED, post_samples=post,
        )
        x = np.vstack((originals["features"], synthetic["features"]))
        y = np.r_[originals["labels"], synthetic["labels"]]
        weights = np.r_[originals["sample_weight"], synthetic["sample_weight"]]
        prepared = time.perf_counter()
        baseline = fit_model(x, y, weights, n_estimators=trees)
        baseline_end = time.perf_counter()
        columns = np.arange(len(names)) if count == 38 else select_top_features(baseline)
        model = baseline if count == 38 else fit_model(x[:, columns], y, weights, n_estimators=trees)
        fitted = time.perf_counter()
        selected_names = [names[index] for index in columns]
        benchmark = benchmark_mobile(model, windows, selected_names)
        model_path = models_dir / f"{label}_model.json"
        model.save_model(model_path)
        loaded = XGBClassifier()
        loaded.load_model(model_path)
        np.testing.assert_array_equal(
            loaded.predict_proba(x[:, columns]), model.predict_proba(x[:, columns]),
        )
        threshold = float(np.nextafter(np.float32(predictions[labels == 0].max()), np.float32(np.inf)))
        all_results[label] = {
            "trees": trees, "features": count, "post_seconds": post / FS,
            "metrics_0_5": classification_metrics(labels, event_ids, predictions, sessions, 0.5),
            "metrics_zero_fa_oof": classification_metrics(labels, event_ids, predictions, sessions, threshold),
            "benchmark": benchmark, "folds": fold_details,
            "fold_training_examples_min": min(fold_sizes), "fold_training_examples_max": max(fold_sizes),
            "final_training": {
                "real_examples": len(labels), "synthetic_examples": len(synthetic["labels"]),
                "positive_examples": int(y.sum()), "negative_examples": int((y == 0).sum()),
                "augmentation_and_matrix_s": prepared - start,
                "baseline_fit_s": baseline_end - prepared,
                "selection_and_refit_s": fitted - baseline_end,
                "total_training_s": fitted - start,
            },
            "model_path": str(model_path.resolve()),
            "model_json_kib": model_path.stat().st_size / 1024,
            "model_sha256": hashlib.sha256(model_path.read_bytes()).hexdigest(),
            "feature_names": selected_names,
            "feature_importance_gain": {
                name: float(value) for name, value in zip(selected_names, model.feature_importances_)
            },
            "oof_predictions": [
                {"index": index, "session_id": str(groups[index]), "label": int(labels[index]),
                 "event_id": str(event_ids[index]), "probability": float(probability)}
                for index, probability in enumerate(predictions)
            ],
        }

    import scipy
    import sklearn
    import xgboost

    dataset = {
        "sessions": len(sessions), "fall_sessions": sum(bool(s["impacts"]) for s in sessions),
        "nonfall_sessions": sum(not s["impacts"] for s in sessions),
        "events": sum(len(s["impacts"]) for s in sessions),
        "real_candidates": len(labels), "positive_candidates": int(labels.sum()),
        "negative_candidates": int((labels == 0).sum()),
        "nonfall_minutes": sum(s["nonfall_seconds"] for s in sessions) / 60,
        "resampled_samples": sum(len(s["time"]) for s in sessions),
        "resampled_duration_s": sum(float(s["time"][-1]) for s in sessions),
    }
    report_path = Path(__file__).resolve().parent / "training_report.md"
    results = {
        "generated_at": datetime.now().astimezone().isoformat(),
        "environment": {"python": platform.python_version(), "platform": platform.platform(),
                        "processor": platform.machine(), "numpy": np.__version__, "pandas": pd.__version__,
                        "scipy": scipy.__version__, "sklearn": sklearn.__version__, "xgboost": xgboost.__version__},
        "dataset": dataset, "models": all_results,
        "comparison_runtime_s": time.perf_counter() - comparison_start,
        "training_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    complete, light = all_results["completo"], all_results["leggero"]
    speedup = complete["benchmark"]["combined_mean_ms"] / light["benchmark"]["combined_mean_ms"]
    lines = [
        "# Report unico: addestramento e confronto XGBoost",
        "",
        f"Aggiornamento: {results['generated_at']}. Questo documento sostituisce il precedente report.",
        "Fonte corrente per il paper: risultati ricalcolati sui dati originali, non numeri stimati.",
        "Le nuove informazioni rilevanti e le relative descrizioni vanno mantenute in questo file.",
        "",
        "## 1. Sintesi del confronto",
        "",
        "Completo: 200 alberi, 38 feature, post-impatto 1,5 s. "
        "Leggero: 100 alberi, 25 feature, post-impatto 1,0 s. Entrambi depth=3.",
        "Il confronto modifica contemporaneamente alberi, feature e finestra: "
        "non isola l'effetto causale di una singola ottimizzazione.",
        "",
        "### Metriche OOF alla soglia fissa 0,5",
        "",
        "| Modello | Accuracy % | Precision % | Recall candidati % | F1 % | Specificita % | Balanced accuracy % | MCC |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for name, result in all_results.items():
        m = result["metrics_0_5"]
        lines.append(f"| {name} | {100*m['accuracy']:.2f} | {100*m['precision']:.2f} | "
                     f"{100*m['recall_candidates']:.2f} | {100*m['f1']:.2f} | "
                     f"{100*m['specificity']:.2f} | {100*m['balanced_accuracy']:.2f} | {m['mcc']:.4f} |")
    lines.extend([
        "",
        "| Modello | TP | FP | TN | FN | Cadute trovate | Recall eventi % | FA/min | ROC-AUC | PR-AUC | AP |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for name, result in all_results.items():
        m = result["metrics_0_5"]
        lines.append(f"| {name} | {m['tp']} | {m['fp']} | {m['tn']} | {m['fn']} | "
                     f"{m['falls_found']}/{m['falls_total']} | {100*m['recall_events']:.2f} | "
                     f"{m['false_alarms_per_minute']:.4f} | {m['roc_auc']:.4f} | {m['pr_auc']:.4f} | "
                     f"{m['average_precision']:.4f} |")
    lines.extend([
        "", "### Tempo di esecuzione e dimensioni", "",
        "Tempi Python sul computer indicato sotto, NON sul telefono. "
        "1000 finestre reali ripetute con seed 42, 30 warm-up, batch=1. "
        "Il tempo predict include il wrapper sklearn/XGBoost e la conversione della matrice.",
        "",
        "| Modello | Estrazione media ms | Predict medio ms | Totale medio ms | Mediana ms | P95 ms | JSON KiB | Attesa post + media calcolo ms |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for name, result in all_results.items():
        b = result["benchmark"]
        lines.append(f"| {name} | {b['feature_mean_ms']:.6f} | {b['predict_mean_ms']:.6f} | "
                     f"{b['combined_mean_ms']:.6f} | {b['combined_median_ms']:.6f} | "
                     f"{b['combined_p95_ms']:.6f} | {result['model_json_kib']:.2f} | "
                     f"{result['post_seconds']*1000+b['combined_mean_ms']:.6f} |")
    lines.extend([
        "", f"Speedup medio leggero vs completo per estrazione+predict: {speedup:.3f}x.",
        "P95 = valore sotto cui cade il 95% delle 1000 misure; non e un worst-case garantito.",
        "I tempi dipendono da host, carico e runtime: variazioni tra esecuzioni sono normali.",
        "Attesa post + calcolo assume un impatto gia localizzato. NMS globale e "
        "ricentraggio +/-3 s sono offline: NON e la latenza end-to-end di un detector su telefono.",
        "",
        "### Tempo di training",
        "",
        "| Modello | Training fold medio s | Fold std s (ddof=0) | Fit finale baseline s | Selezione+refit finale s | Augmentation finale s | Training finale totale s |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ])
    for name, result in all_results.items():
        elapsed = [fold["total_training_s"] for fold in result["folds"]]
        final = result["final_training"]
        lines.append(f"| {name} | {np.mean(elapsed):.6f} | {np.std(elapsed):.6f} | "
                     f"{final['baseline_fit_s']:.6f} | {final['selection_and_refit_s']:.6f} | "
                     f"{final['augmentation_and_matrix_s']:.6f} | {final['total_training_s']:.6f} |")
    lines.extend([
        "",
        "Training fold include augmentation, estrazione/matrice e fit; esclude caricamento, "
        "ricampionamento e segmentazione iniziali. Il leggero include un primo fit a 100 alberi/"
        "38 feature per la selezione, poi il refit a 25. I tempi finali sono una singola misura.",
        "",
        "### Soglia calibrata a zero falsi allarmi OOF",
        "",
        "| Modello | Soglia >= | Accuracy % | Precision % | Recall candidati % | F1 % | Cadute trovate | FA/min |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for name, result in all_results.items():
        m = result["metrics_zero_fa_oof"]
        lines.append(f"| {name} | {m['threshold']:.17g} | {100*m['accuracy']:.2f} | {100*m['precision']:.2f} | "
                     f"{100*m['recall_candidates']:.2f} | {100*m['f1']:.2f} | "
                     f"{m['falls_found']}/{m['falls_total']} | {m['false_alarms_per_minute']:.4f} |")
    lines.extend([
        "",
        "Soglia = successivo Float32 sopra il massimo negativo OOF. Calibrata e valutata sugli "
        "stessi OOF: risultato descrittivo, non indipendente e non garanzia di zero FA futuri. "
        "I JSON XGBoost non incorporano la soglia operativa: applicarla esternamente.",
        "",
        "## 2. Dataset e protocollo",
        "",
        f"- {dataset['sessions']} sessioni, {dataset['fall_sessions']} con cadute, "
        f"{dataset['nonfall_sessions']} senza; {dataset['events']} eventi annotati.",
        f"- {dataset['resampled_samples']} campioni ricampionati a 30 Hz; somma durate "
        f"delle griglie {dataset['resampled_duration_s']:.6f} s.",
        f"- Tempo fuori falling dai timestamp originali: {dataset['nonfall_minutes']:.10f} min.",
        f"- {dataset['real_candidates']} candidati valutati: {dataset['positive_candidates']} positivi, "
        f"{dataset['negative_candidates']} negativi. Una caduta senza candidato valido resta nel totale eventi.",
        "- Dati di un soggetto, cadute simulate su materasso: informazioni dichiarate dall'utente, "
        "non dedotte dai CSV. Modello esatto del dispositivo, eta/salute e procedura di annotazione: "
        "[DA COMPLETARE]. La mappatura camminata/scale per sessione non e verificata.",
        "- Sensori: accelerometro XYZ in m/s^2 con gravita, gyro XYZ in rad/s; "
        "magnetometro/quaternione esclusi. X laterale, Y verticale in piedi, Z avanti/indietro.",
        "- Timestamp_ns interi prima della conversione; interpolazione lineare a 30 Hz, "
        "replica ai bordi e per finestre incomplete. Nessuna modifica ai CSV originali.",
        "- Un tratto contiguo falling=1 = un evento. Candidati da massimi |a|>15 oppure minimi "
        "|a|<0,6g, g=9,80665; NMS globale a distanza 1 s con priorita abs(|a|-g).",
        "- Un positivo per evento entro +/-0,3 s dal picco annotato. Negativi fuori falling +/-1 s; "
        "ambigui scartati. Positivi ricentrati sull'argmax di segment_fall entro +/-3 s.",
        "- LOSO: 17 fold, 16 sessioni train/1 test; stessi split nei due modelli. "
        "Nessuno split casuale di finestre; nessuna sessione test tra i donatori.",
        "- Metriche aggregate sulle predizioni out-of-fold, non medie per fold e non training accuracy.",
        "- Top25 selezionate con gain sul solo training di ciascun fold; ordine originale "
        "stabile per i pari merito. Selezione finale su tutti i dati solo dopo la valutazione.",
        "",
        "## 3. Modello, augmentation e feature",
        "",
        "- Parametri comuni: max_depth=3, learning_rate=0.05, subsample=0.8, "
        "colsample_bytree=0.8, base_score=0.5, hist, binary:logistic, logloss, n_jobs=1, seed=42.",
        "- scale_pos_weight = negativi/positivi del training aumentato; sample_weight=1 reali, 0.4 sintetici.",
        "- Per positivo: 15 trasformazioni + 15 ricombinazioni; per negativo: 1 trasformazione, "
        "1 negativo urto, 1 negativo gyro. Reali e sintetici separati con origine e donatori.",
        "- Rotazione condivisa acc/gyro +/-15 gradi; scala dinamica acc e gyro +/-20%, "
        "gravita passa-basso 0.3 Hz invariata rispetto alla scala; warp +/-10% con "
        "compensazione urto; shift +/-0.3 s; rumore sigma acc=0.15 e gyro=0.03; "
        "drop fino al 10% e reinterpolazione.",
        "- Specchio su meta copie positive: acc x invertita; gyro y/z invertiti. "
        "Ricombinazioni da 3 sessioni train distinte, crossfade 0.3 s e allineamento post.",
        "- Negativi difficili: non-falling + solo urto senza cambio sistematico inclinazione; "
        "non-falling con gyro x1.5-2 senza picchi acc. Non-falling e proxy, non camminata verificata.",
        "- Training finale: 48 reali + 522 sintetici = 570; 434 positivi, 136 negativi. "
        "Nessuna augmentation nel test; solo training dopo lo split.",
        "- Feature semplici; std ddof=0, nessuna FFT. Pre 45 campioni; post 46 completo/31 leggero. "
        "Le finestre includono centro e ultimo estremo nel post. Input leggero 76x6, completo 91x6.",
        "",
        "### Formule e unita di tutte le feature",
        "",
        "a=sqrt(ax^2+ay^2+az^2), omega=sqrt(gx^2+gy^2+gz^2); "
        "angle(u,v)=acos(clamp(dot(u,v)/(norm(u)*norm(v)),-1,1))*180/pi. "
        "Argmin/argmax indicano la prima occorrenza. Angoli da accelerazione media sono proxy di gravita.",
        "",
        "| Feature | Formula | Unita |",
        "|---|---|---|",
    ])
    for item in feature_definitions():
        lines.append(f"| {item['name']} | `{item['formula']}` | {item['unit']} |")
    for name, result in all_results.items():
        lines.extend(["", f"### Ordine input finale: {name}", "",
                      ", ".join(f"`{feature}`" for feature in result["feature_names"]),
                      "", f"Modello: `{result['model_path']}`.",
                      f"SHA-256: `{result['model_sha256']}`.",
                      "Importanza gain del modello finale (descrittiva, non test indipendente):", "",
                      "| Feature | Gain normalizzato |", "|---|---:|"])
        for feature, gain in sorted(result["feature_importance_gain"].items(), key=lambda item: -item[1]):
            lines.append(f"| {feature} | {gain:.6f} |")
    lines.extend([
        "", "## 4. Definizioni delle metriche", "",
        "- TP: candidato caduta correttamente segnalato; FN: candidato caduta perso. "
        "FP: candidato negativo segnalato; TN: negativo correttamente respinto.",
        "- Accuracy=(TP+TN)/N: quota corretta sui candidati valutati, NON sui campioni IMU.",
        "- Precision=TP/(TP+FP): frazione delle segnalazioni che sono positive.",
        "- Recall candidati=TP/(TP+FN); specificita=TN/(TN+FP).",
        "- F1=2TP/(2TP+FP+FN); balanced accuracy=(recall+specificita)/2.",
        "- MCC=(TP*TN-FP*FN)/sqrt((TP+FP)(TP+FN)(TN+FP)(TN+FN)).",
        "- Event recall=cadute trovate/tutte le cadute, incluse quelle senza candidato. "
        "Non confonderlo con recall candidati: denominatori diversi (15 e 14).",
        "- FA/min=FP/minuti fuori falling. La durata include le fasce di esclusione +/-1s "
        "mentre i candidati ambigui esclusi non sono valutati: possibile sottostima rispetto allo streaming continuo.",
        "- ROC-AUC: area sotto sensibilita vs tasso falsi positivi al variare della soglia. "
        "PR-AUC: integrale trapezoidale precision-recall. AP: average precision, integrazione "
        "a gradini; non intercambiabile con PR-AUC. Non sono percentuali di accuracy.",
        "- Le confusion matrix hanno righe reale [0,1], colonne predetto [0,1], cioe [[TN,FP],[FN,TP]].",
        "",
        "## 5. Informazioni gia acquisite e limiti", "",
        "- Piccolo dataset, un soggetto dichiarato, cadute simulate: LOSO non e validazione "
        "inter-soggetto o su cadute reali. Nessun test esterno, intervallo di confidenza o significativita dimostrata.",
        "- La localizzazione delle finestre positive usa annotazioni e ricentraggio offline; "
        "un massimo +/-3s puo cadere fuori falling. Prestazioni non end-to-end/causali.",
        "- Ricampionamento 30 Hz non ricrea gli urti persi tra campioni; augmentation non crea nuovi soggetti.",
        "- segment_fall esporta fasi e metriche in fall_segments.json: onset da ultima "
        "bassa accelerazione <0.6g o gyro>3; end da std(|a|)<0.5 su 0.5s e "
        "variazione gravita<5 gradi su 1s, entro +/-3s; got_up da ritorno a +Y entro30 gradi "
        "dopo esserne usciti. Assenti=null, non interpolati o inventati.",
        "- estimated_height=0.5*9.81*(impact-onset)^2 e un proxy balistico NON VALIDATO, "
        "anche per onset giroscopico; non riportarlo come altezza reale.",
        "- I plot delle fasi sono nelle cartelle delle sessioni; overview in plots_segments/. "
        "Nessun plot, JSON segmentazione o dato preesistente modificato da questo confronto.",
        "- Export mobile precedente: m2cgen Java->Kotlin, 25 feature, golden test 10+10. "
        "I golden sono test numerici, non prestazioni su test indipendente.",
        "- Questo comando NON aggiorna l'export Kotlin, golden o features.json dell'app: "
        "i due modelli del confronto sono separati in models/comparison/; usare l'ordine qui riportato.",
        "",
        "## 6. Risultati per sessione (OOF, versione leggera)", "",
        "| Sessione | Cadute annotate | Candidati positivi | Candidati negativi | Probabilita massima candidati |",
        "|---|---:|---:|---:|---:|",
    ])
    for session in sessions:
        rows = [row for row in light["oof_predictions"] if row["session_id"] == session["id"]]
        maximum = f"{max(row['probability'] for row in rows):.8f}" if rows else "n/d"
        lines.append(f"| {session['id']} | {len(session['impacts'])} | "
                     f"{sum(row['label'] for row in rows)} | "
                     f"{sum(row['label'] == 0 for row in rows)} | {maximum} |")
    lines.extend([
        "", "## 7. Riproduzione e provenienza", "",
        "Comando: `python3 train_fall.py --compare-models`.",
        "Il comando riallena entrambi i modelli, rigenera le metriche e sostituisce questo "
        "report con i risultati correnti. Le informazioni metodologiche sono mantenute nel generatore.",
        f"Ambiente: `{json.dumps(results['environment'])}`.",
        f"SHA-256 script: `{results['training_script_sha256']}`.",
        "I dettagli sottostanti includono predizioni OOF, metriche non arrotondate, "
        "feature per fold, tempi, checksum e feature finali: consentono di verificare le tabelle.",
        "",
        "## 8. Dati numerici completi (machine-readable)", "",
        "```json", json.dumps(results, indent=2, allow_nan=False), "```", "",
    ])
    integration_marker = "<!-- integration-notes -->"
    if report_path.exists():
        previous = report_path.read_text(encoding="utf-8")
        if integration_marker in previous:
            lines.extend(["", integration_marker + previous.split(integration_marker, 1)[1]])
    report_path.write_text("\n".join(lines), encoding="utf-8")
    print("\n=== CONFRONTO FINALE (soglia 0.5) ===")
    for name, result in all_results.items():
        m, b = result["metrics_0_5"], result["benchmark"]
        print(f"{name}: accuracy={m['accuracy']:.4f}, precision={m['precision']:.4f}, "
              f"recall={m['recall_candidates']:.4f}, F1={m['f1']:.4f}, "
              f"PR-AUC={m['pr_auc']:.4f}, {m['falls_found']}/{m['falls_total']} cadute, "
              f"FA/min={m['false_alarms_per_minute']:.4f}, calcolo={b['combined_mean_ms']:.6f}ms")
    print(f"Speedup leggero={speedup:.3f}x; report unico aggiornato: {report_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", type=Path, default=Path(__file__).resolve().parent / "data")
    parser.add_argument(
        "--compare-models", action="store_true",
        help="Riallena completo 200/38/1.5s e leggero 100/25/1s; aggiorna training_report.md",
    )
    parser.add_argument(
        "--kotlin-compiler", type=Path,
        help="Percorso a kotlinc per compilare e verificare l'export contro XGBoost",
    )
    parser.add_argument(
        "--segments-only", action="store_true",
        help="Crea solo fall_segments.json e nuovi PNG in plots_segments/, senza aggiornare modelli",
    )
    parser.add_argument(
        "--overwrite-segment-plots", action="store_true",
        help="Consenso esplicito a rigenerare solo i PNG delle fasi; richiede --segments-only",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=Path(__file__).resolve().parent / "models",
        help="Cartella per i quattro output mobile (default: models)",
    )
    args = parser.parse_args()
    if args.compare_models and (args.segments_only or args.kotlin_compiler is not None):
        parser.error("--compare-models non si combina con --segments-only o --kotlin-compiler")
    if args.overwrite_segment_plots and not args.segments_only:
        parser.error("--overwrite-segment-plots richiede --segments-only")
    if args.segments_only and not args.overwrite_segment_plots:
        root = Path(__file__).resolve().parent
        if (root / "plots_segments").exists() or (root / "fall_segments.json").exists():
            parser.error("Output segmentazione gia esistente: serve autorizzazione prima di sovrascrivere")
    sessions = load_sessions(args.data_dir)
    print("\nSegmentazione automatica delle cadute (altezza = proxy balistico NON VALIDATO):")
    segment_rows = []
    for session in sessions:
        for event, segment in enumerate(session["segments"], start=1):
            segment_rows.append({
                "sessione": session["id"], "caduta": event,
                **{name: segment[name] for name in (
                    "onset_time", "impact_time", "end_time", "fall_duration",
                    "estimated_height", "peak_acc", "n_impacts",
                    "rotation_integrated", "side", "time_to_still", "got_up", "got_up_time",
                )},
            })
    print(pd.DataFrame(segment_rows).to_string(index=False, na_rep="non trovato"))
    if args.segments_only:
        export_fall_segments(sessions, overwrite_plots=args.overwrite_segment_plots)
        return
    if args.compare_models:
        compare_models(sessions, args.output_dir)
        return
    optimize_mobile(sessions, args.output_dir, args.kotlin_compiler)


if __name__ == "__main__":
    main()
