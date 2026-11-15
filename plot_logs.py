#!/usr/bin/env python3
"""Crea motion_plots.png nelle sessioni non ancora elaborate."""

from __future__ import annotations

import argparse
import csv
import json
import logging
import tempfile
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.axes import Axes
from numpy.typing import NDArray


LOGGER = logging.getLogger(__name__)
OUTPUT_NAME = "motion_plots.png"
CHANNELS = {
    "accelerometer": ("x", "y", "z"),
    "gyroscope": ("x", "y", "z"),
    "magnetometer": ("x", "y", "z"),
    "orientation": ("w", "x", "y", "z"),
}
COLORS = ("tab:blue", "tab:orange", "tab:green", "tab:purple")


@dataclass
class MotionLog:
    source: str
    clock: str
    time: NDArray[np.float64]
    values: dict[str, NDArray[np.float64]]
    falling: NDArray[np.bool_]


def load_logs(path: Path) -> list[MotionLog]:
    groups: dict[tuple[str, str], list[tuple[int, bool, list[float]]]] = {}
    columns = [
        f"{sensor}_{axis}"
        for sensor, axes in CHANNELS.items()
        for axis in axes
    ]
    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        required = {"timestamp_ns", "source", "clock_domain", "falling"}
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{path}: colonne mancanti: {', '.join(sorted(missing))}")
        if not set(columns).intersection(reader.fieldnames or []):
            raise ValueError(f"{path}: nessuna colonna sensore riconosciuta")
        for row in reader:
            try:
                timestamp = int(row["timestamp_ns"])
                source, clock = row["source"], row["clock_domain"]
                if not source or not clock:
                    raise ValueError("source o clock_domain vuoto")
                if row["falling"] not in ("0", "1"):
                    raise ValueError("falling deve essere 0 oppure 1")
                values = []
                for column in columns:
                    raw = row.get(column)
                    value = float(raw) if raw else np.nan
                    if raw and not np.isfinite(value):
                        raise ValueError(f"{column}: valore non finito {raw!r}")
                    values.append(value)
                groups.setdefault((source, clock), []).append(
                    (timestamp, row["falling"] == "1", values)
                )
            except (TypeError, ValueError) as error:
                raise ValueError(f"{path}, riga {reader.line_num}: {error}") from error
    if not groups:
        raise ValueError(f"{path}: nessun campione")

    logs = []
    for (source, clock), samples in sorted(groups.items()):
        if any(a[0] > b[0] for a, b in zip(samples, samples[1:])):
            LOGGER.warning("%s: timestamp fuori ordine per %s; riordino", path, source)
        samples.sort(key=lambda sample: sample[0])
        origin = samples[0][0]
        # Sottrarre gli interi prima della conversione preserva la precisione in ns.
        time = np.array([(sample[0] - origin) / 1e9 for sample in samples])
        matrix = np.array([sample[2] for sample in samples], dtype=float)
        if not np.isfinite(matrix).any():
            raise ValueError(f"{path}: tutti i sensori sono vuoti per {source}")
        logs.append(
            MotionLog(
                source,
                clock,
                time,
                {column: matrix[:, index] for index, column in enumerate(columns)},
                np.array([sample[1] for sample in samples], dtype=bool),
            )
        )
    return logs


def fall_spans(log: MotionLog) -> list[tuple[float, float]]:
    """Intervalli delimitati dai punti medi tra campioni contigui."""
    time = log.time
    if len(time) == 1:
        return []
    edges = np.concatenate(([time[0]], (time[:-1] + time[1:]) / 2, [time[-1]]))
    changes = np.diff(np.concatenate(([False], log.falling, [False])).astype(int))
    return [
        (float(edges[start]), float(edges[end]))
        for start, end in zip(np.flatnonzero(changes == 1), np.flatnonzero(changes == -1))
    ]


def plot_series(
    axis: Axes,
    time: NDArray[np.float64],
    series: list[tuple[str, NDArray[np.float64]]],
    title: str,
    unit: str,
) -> None:
    axis.set_title(title, fontsize=11, loc="left")
    axis.set_ylabel(unit)
    has_data = False
    for color, (label, values) in zip(COLORS, series):
        if np.isfinite(values).any():
            axis.plot(time, values, label=label, color=color, linewidth=1, marker=".", markersize=2)
            has_data = True
    if has_data:
        axis.legend(loc="upper right", fontsize=8)
    else:
        axis.text(0.5, 0.5, "Dati non disponibili", ha="center", transform=axis.transAxes)
    axis.grid(alpha=0.25)
    axis.set_xlabel("Tempo dal primo campione dello stream [s]")


def create_plot(folder: Path, output: Path) -> None:
    logs = load_logs(folder / "motion.csv")
    with (folder / "session.json").open(encoding="utf-8") as stream:
        metadata = json.load(stream)
    if not isinstance(metadata, dict) or not isinstance(metadata.get("units"), dict):
        raise ValueError(f"{folder / 'session.json'}: oggetto units mancante o non valido")
    units = metadata["units"]

    figure, grid = plt.subplots(
        4 * len(logs), 2, figsize=(18, 14 * len(logs)), squeeze=False,
        layout="constrained",
    )
    try:
        figure.suptitle(
            f"Sessione {folder.name}\n"
            "Rosso = annotazioni falling del CSV (non rilevamento automatico)",
            fontsize=15,
        )
        for index, log in enumerate(logs):
            axes = grid[index * 4:(index + 1) * 4]
            for axis in axes.flat:
                if axis is not axes[0, 0]:
                    axis.sharex(axes[0, 0])
                for start, end in fall_spans(log):
                    axis.axvspan(start, end, color="tab:red", alpha=0.13)
                if len(log.time) == 1 and log.falling[0]:
                    axis.axvline(log.time[0], color="tab:red", alpha=0.5)

            acceleration_unit = str(units.get("accelerometer", "unita non specificata"))
            for component, axis, color in zip("xyz", axes[:3, 0], COLORS):
                plot_series(
                    axis, log.time,
                    [(f"a{component}", log.values[f"accelerometer_{component}"])],
                    f"Accelerometro - asse {component.upper()}", acceleration_unit,
                )
                if axis.lines:
                    axis.lines[-1].set_color(color)

            acceleration = np.column_stack(
                [log.values[f"accelerometer_{component}"] for component in "xyz"]
            )
            norm = np.linalg.norm(acceleration, axis=1)
            plot_series(
                axes[3, 0], log.time, [("|a|", norm)],
                "Modulo accelerazione (include la gravita se presente nel sensore)",
                acceleration_unit,
            )
            for row, sensor, title in (
                (0, "gyroscope", "Giroscopio"),
                (1, "magnetometer", "Magnetometro"),
                (2, "orientation", "Orientamento - quaternione, non angoli di Eulero"),
            ):
                plot_series(
                    axes[row, 1], log.time,
                    [(component, log.values[f"{sensor}_{component}"])
                     for component in CHANNELS[sensor]],
                    title,
                    "adimensionale" if sensor == "orientation"
                    else str(units.get(sensor, "unita non specificata")),
                )
            delta = np.diff(log.time)
            positive = delta[delta > 0]
            rate = f"{1 / np.median(positive):.2f} Hz" if positive.size else "n/d"
            plot_series(
                axes[3, 1], log.time[1:], [("dt", delta * 1000)],
                f"Campionamento - frequenza mediana {rate}; "
                f"timestamp duplicati: {np.count_nonzero(delta == 0)}",
                "Intervallo [ms]",
            )
            expected_rate = metadata.get("sampling_rate_hz")
            if isinstance(expected_rate, (float, int)) and expected_rate > 0:
                axes[3, 1].axhline(
                    1000 / expected_rate, color="black", linestyle="--",
                    linewidth=0.8, label=f"Atteso: {expected_rate:g} Hz",
                )
                axes[3, 1].legend(loc="upper right", fontsize=8)
            axes[0, 0].set_title(
                f"{log.source} | {log.clock}\n"
                f"{len(log.time)} campioni | {log.time[-1]:.2f} s | "
                f"{np.count_nonzero(log.falling)} campioni falling\n"
                "Accelerometro - asse X",
                loc="left", fontsize=10,
            )

        # Un salvataggio interrotto non deve lasciare un PNG che verrebbe saltato.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                dir=folder, prefix=".motion_plots-", suffix=".png", delete=False,
            ) as stream:
                temporary = Path(stream.name)
            figure.savefig(temporary, dpi=150, format="png")
            temporary.replace(output)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    finally:
        plt.close(figure)


def process_folders(data_dir: Path) -> int:
    if not data_dir.is_dir():
        LOGGER.error("Cartella data inesistente o non valida: %s", data_dir)
        return 1
    created = skipped = failed = 0
    for folder in sorted(data_dir.iterdir()):
        if not folder.is_dir():
            continue
        output = folder / OUTPUT_NAME
        if output.is_file():
            LOGGER.info("[SKIP] %s: %s gia presente", folder.name, OUTPUT_NAME)
            skipped += 1
            continue
        try:
            create_plot(folder, output)
        except (OSError, ValueError, csv.Error) as error:
            LOGGER.error("[ERRORE] %s: %s", folder.name, error)
            failed += 1
            continue
        LOGGER.info("[OK] %s", output)
        created += 1
    LOGGER.info("Riepilogo: %d create, %d saltate, %d errori", created, skipped, failed)
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-dir", type=Path, default=Path(__file__).resolve().parent / "data",
        help="Cartella delle sessioni (default: data accanto allo script)",
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    return process_folders(args.data_dir)


if __name__ == "__main__":
    raise SystemExit(main())
