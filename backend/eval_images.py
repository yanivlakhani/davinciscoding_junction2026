#!/usr/bin/env python3
"""
Evaluate the vision module on a folder of images via the Modal server (/classify).

Usage:
  pip install requests
  export FALL_API_KEY=...            # same as API_KEY in the Modal secret
  python3 backend/eval_images.py /path/to/dataset
  python3 backend/eval_images.py /path/to/dataset --force   # also send frames rejected by quality gate
  python3 backend/eval_images.py /path/to/dataset --model claude-haiku-5-5   # compare models

Ground truth (optional, first match wins):
  1. labels.csv in the folder: filename,label   (label: ground | not_ground)
  2. subfolder name: ground/ or not_ground/
  3. filename prefix: ground_*.jpg or notground_* / not_ground_*
Without labels: predictions only, no metrics.
PNG and HEIC/HEIF inputs are automatically converted to resized JPEG before upload.

Output (folder/results_<run_id>/):
  predictions.csv   one row per image (paper table / appendix)
  predictions.jsonl raw server responses
  summary.json      metrics + latency + run metadata
  summary.md        ready-to-paste tables
Output in the dataset folder:
  evaluation_history.jsonl   append-only record of every image call
  model_comparison.json      cumulative metrics grouped by model and prompt
  model_comparison.md        cumulative model metrics in a comparison table
"""
import argparse, csv, json, os, statistics, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

import requests

DEFAULT_URL = "https://lorejob--fall-detection-backend-fastapi-app.us-east.modal.run"
EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".heic", ".heif"}
COLS = ["image", "label", "pred_on_ground", "caduta", "confidence", "p_fall",
        "sent_to_model", "usable", "brightness", "sharpness", "contrast", "faces_blurred",
        "input_tokens", "output_tokens", "upload_kb",
        "latency_preprocess_ms", "latency_model_ms", "latency_server_ms", "latency_total_ms", "model", "prompt_version",
        "reason", "error"]


def norm_label(s):
    s = (s or "").strip().lower().replace("-", "_")
    if s in {"ground", "on_ground", "yes", "1", "terra", "a_terra"}:
        return "ground"
    if s in {"not_ground", "notground", "no", "0", "standing", "in_piedi"}:
        return "not_ground"
    return ""


def find_label(p: Path, root: Path, table: dict):
    if p.name in table:
        return table[p.name]
    for part in p.relative_to(root).parts[:-1]:
        if norm_label(part):
            return norm_label(part)
    stem = p.stem.lower()
    for pre in ("not_ground_", "notground_", "ground_"):
        if stem.startswith(pre):
            return norm_label(pre.rstrip("_"))
    return ""


def load_bytes(p: Path, max_side: int) -> tuple[bytes, str]:
    """Convert supported source images to resized JPEG before uploading."""
    name = p.stem + ".jpg"
    try:
        from PIL import Image
        im = Image.open(p).convert("RGB")
        im.thumbnail((max_side, max_side))
        import io
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=85)
        return buf.getvalue(), name
    except ImportError:
        pass
    except Exception:
        # Pillow may not support HEIC; try the native macOS converter for all formats.
        pass
    with tempfile.TemporaryDirectory() as d:          # macOS fallback (also HEIC)
        out = Path(d) / name
        subprocess.run(["sips", "-Z", str(max_side), "-s", "format", "jpeg", str(p), "--out", str(out)],
                       check=True, capture_output=True)
        return out.read_bytes(), name


_session = requests.Session()          # keep-alive: no new TLS handshake per image


def classify(url, key, p: Path, force: bool, model, max_side: int):
    t0 = time.time()
    kb = None
    try:
        data, name = load_bytes(p, max_side)
        kb = round(len(data) / 1024, 1)
        form = {"force": str(force).lower()}
        if model:
            form["model"] = model
        r = _session.post(f"{url}/classify", headers={"x-api-key": key},
                          files={"images": (name, data, "image/jpeg")}, data=form, timeout=(10, 60))
        r.raise_for_status()
        res = r.json()
    except Exception as e:
        res = {"error": f"client: {type(e).__name__}: {e}"}
    res["latency_total_ms"] = int((time.time() - t0) * 1000)
    res["upload_kb"] = kb
    return res


def row_of(rel, label, res):
    v, q = res.get("vision") or {}, res.get("quality") or {}
    return {
        "image": rel, "label": label, "pred_on_ground": v.get("on_ground", "uncertain"),
        "caduta": v.get("caduta") or "", "confidence": v.get("confidence", ""), "p_fall": v.get("p_fall"),
        "input_tokens": v.get("input_tokens", ""), "output_tokens": v.get("output_tokens", ""),
        "upload_kb": res.get("upload_kb", ""), "latency_preprocess_ms": res.get("latency_preprocess_ms", ""), "sent_to_model": res.get("sent_to_model", ""),
        "usable": q.get("usable", ""), "brightness": q.get("brightness", ""), "sharpness": q.get("sharpness", ""),
        "contrast": q.get("contrast", ""), "faces_blurred": res.get("faces_blurred", ""),
        "latency_model_ms": res.get("latency_model_ms", ""), "latency_server_ms": res.get("latency_server_ms", ""),
        "latency_total_ms": res.get("latency_total_ms", ""), "model": res.get("model", ""),
        "prompt_version": res.get("prompt_version", ""), "reason": v.get("reason", ""),
        "error": res.get("error") or "",
    }


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else None


def metrics(rows):
    lab = [r for r in rows if r["label"]]
    if not lab:
        return None
    dec = [r for r in lab if r["pred_on_ground"] in ("yes", "no")]
    tp = sum(r["label"] == "ground" and r["pred_on_ground"] == "yes" for r in dec)
    fn = sum(r["label"] == "ground" and r["pred_on_ground"] == "no" for r in dec)
    fp = sum(r["label"] == "not_ground" and r["pred_on_ground"] == "yes" for r in dec)
    tn = sum(r["label"] == "not_ground" and r["pred_on_ground"] == "no" for r in dec)
    unc_g = sum(r["label"] == "ground" and r["pred_on_ground"] == "uncertain" for r in lab)
    unc_n = sum(r["label"] == "not_ground" and r["pred_on_ground"] == "uncertain" for r in lab)
    div = lambda a, b: round(a / b, 4) if b else None
    prec, rec = div(tp, tp + fp), div(tp, tp + fn)
    f1 = div(2 * tp, 2 * tp + fp + fn)
    # conservative view for safety: "uncertain" counts as "on ground" (escalate, never dismiss)
    tp_s, fp_s = tp + unc_g, fp + unc_n
    sc = [(r["p_fall"], r["label"] == "ground") for r in lab if isinstance(r["p_fall"], (int, float))]
    pos, neg = [x for x, y in sc if y], [x for x, y in sc if not y]
    auc = (round(sum((a > b) + 0.5 * (a == b) for a in pos for b in neg) / (len(pos) * len(neg)), 4)
           if pos and neg else None)
    return {
        "roc_auc_p_fall": auc,
        "n_labeled": len(lab), "n_ground": sum(r["label"] == "ground" for r in lab),
        "n_not_ground": sum(r["label"] == "not_ground" for r in lab),
        "coverage": div(len(dec), len(lab)),
        "confusion_decided": {"TP": tp, "FN": fn, "FP": fp, "TN": tn},
        "uncertain": {"ground": unc_g, "not_ground": unc_n},
        "accuracy": div(tp + tn, len(dec)), "precision": prec, "recall": rec,
        "specificity": div(tn, tn + fp), "f1": f1,
        "safety_mode_uncertain_as_ground": {
            "recall": div(tp_s, tp_s + fn), "specificity": div(tn, tn + fp_s),
            "accuracy": div(tp_s + tn, len(lab))},
    }


def write_md(path, s):
    L = [f"# Vision on-ground evaluation", "",
         f"- Date: {s['run']['date']}", f"- Model: {s['run']['model']} (prompt {s['run']['prompt_version']})",
         f"- Images: {s['n_images']} (sent to model: {s['n_sent_to_model']}, quality-gate rejected: "
         f"{s['n_quality_rejected']}, errors: {s['n_errors']})", f"- force: {s['run']['force']}", "",
         "## Predictions", "", "| on_ground | n |", "|---|---|"]
    L += [f"| {k} | {v} |" for k, v in s["pred_counts"].items()]
    m = s["metrics"]
    if m:
        c = m["confusion_decided"]
        L += ["", "## Confusion matrix (decided cases)", "",
              "| | pred yes | pred no | uncertain |", "|---|---|---|---|",
              f"| **ground** | {c['TP']} | {c['FN']} | {m['uncertain']['ground']} |",
              f"| **not ground** | {c['FP']} | {c['TN']} | {m['uncertain']['not_ground']} |", "",
              "## Metrics", "", "| metric | decided only | uncertain → ground |", "|---|---|---|",
              f"| coverage | {m['coverage']} | 1.0 |",
              f"| accuracy | {m['accuracy']} | {m['safety_mode_uncertain_as_ground']['accuracy']} |",
              f"| precision | {m['precision']} | – |",
              f"| recall (sensitivity) | {m['recall']} | {m['safety_mode_uncertain_as_ground']['recall']} |",
              f"| specificity | {m['specificity']} | {m['safety_mode_uncertain_as_ground']['specificity']} |",
              f"| F1 | {m['f1']} | – |",
              f"| ROC-AUC (p_fall) | {m['roc_auc_p_fall']} | – |"]
    lt = s["latency_ms"]
    L += ["", "## Latency (ms)", "", "| stage | median | p95 |", "|---|---|---|"]
    L += [f"| {k} | {v['median']} | {v['p95']} |" for k, v in lt.items()]
    Path(path).write_text("\n".join(L) + "\n")


def load_history(path):
    records = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8") as f:
        for line_number, line in enumerate(f, 1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as e:
                raise ValueError(f"invalid JSON in {path} at line {line_number}") from e
            if not isinstance(record, dict):
                raise ValueError(f"expected a JSON object in {path} at line {line_number}")
            records.append(record)
    return records


def latency_summary(rows, key):
    values = [row[key] for row in rows if isinstance(row.get(key), int)]
    return {
        "median": statistics.median(values) if values else None,
        "p95": pct(values, 0.95),
    }


def model_comparison(records):
    groups = {}
    for record in records:
        model = record.get("model") or "unknown"
        if not model.startswith("claude-"):
            continue
        key = (model, record.get("prompt_version") or "unknown")
        groups.setdefault(key, []).append(record)

    comparison = []
    latency_keys = ("latency_preprocess_ms", "latency_model_ms", "latency_server_ms", "latency_total_ms")
    for (model, prompt_version), rows in sorted(groups.items()):
        comparison.append({
            "model": model,
            "prompt_version": prompt_version,
            "n_calls": len(rows),
            "n_sent_to_model": sum(row.get("sent_to_model") is True for row in rows),
            "n_quality_rejected": sum(row.get("sent_to_model") is False for row in rows),
            "n_errors": sum(bool(row.get("error")) for row in rows),
            "pred_counts": {
                label: sum(row.get("pred_on_ground") == label for row in rows)
                for label in ("yes", "no", "uncertain")
            },
            "metrics": metrics(rows),
            "latency_ms": {key: latency_summary(rows, key) for key in latency_keys},
        })
    return comparison


def write_model_comparison(path, comparison, updated_at, history_file):
    columns = [
        ("Model", "model"),
        ("Prompt", "prompt_version"),
        ("Calls", "n_calls"),
        ("Sent", "n_sent_to_model"),
        ("Errors", "n_errors"),
        ("Accuracy", "accuracy"),
        ("Precision", "precision"),
        ("Recall", "recall"),
        ("Specificity", "specificity"),
        ("F1", "f1"),
        ("ROC-AUC", "roc_auc_p_fall"),
        ("Latency median ms", "latency_median"),
        ("Latency p95 ms", "latency_p95"),
    ]
    lines = [
        "# Model comparison",
        "",
        f"- Updated: {updated_at}",
        f"- Call history: `{history_file}`",
        "",
        "| " + " | ".join(title for title, _ in columns) + " |",
        "| " + " | ".join("---" for _ in columns) + " |",
    ]
    for row in comparison:
        model_metrics = row.get("metrics") or {}
        median = row["latency_ms"]["latency_model_ms"]["median"]
        p95 = row["latency_ms"]["latency_model_ms"]["p95"]
        values = {
            "model": row["model"],
            "prompt_version": row["prompt_version"],
            "n_calls": row["n_calls"],
            "n_sent_to_model": row["n_sent_to_model"],
            "n_errors": row["n_errors"],
            "accuracy": model_metrics.get("accuracy"),
            "precision": model_metrics.get("precision"),
            "recall": model_metrics.get("recall"),
            "specificity": model_metrics.get("specificity"),
            "f1": model_metrics.get("f1"),
            "roc_auc_p_fall": model_metrics.get("roc_auc_p_fall"),
            "latency_median": median,
            "latency_p95": p95,
        }
        rendered = []
        for _, key in columns:
            value = values[key]
            if value is None:
                rendered.append("n/a")
            elif key in {"accuracy", "precision", "recall", "specificity", "f1", "roc_auc_p_fall"}:
                rendered.append(f"{value:.3f}")
            else:
                rendered.append(str(value))
        lines.append("| " + " | ".join(rendered) + " |")
    if not comparison:
        lines.append("| No calls recorded yet | | | | | | | | | | | | |")
    lines.extend([
        "",
        "Quality metrics require ground-truth labels. Latency columns report model-call time.",
        "Uncertain predictions are excluded from the standard accuracy/precision/recall/F1 metrics.",
        "For safety-aware recall and accuracy, see `model_comparison.json`.",
        "",
    ])
    Path(path).write_text("\n".join(lines), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--url", default=os.environ.get("FALL_API_URL", DEFAULT_URL))
    ap.add_argument("--key", default=os.environ.get("FALL_API_KEY"))
    ap.add_argument("--force", action="store_true", help="send images even if quality gate rejects them")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--model", default=None, help="claude-sonnet-5-5 | claude-haiku-5-5 | claude-opus-5-5")
    ap.add_argument("--max-side", type=int, default=768, help="client-side resize before upload")
    a = ap.parse_args()
    if not a.key:
        sys.exit("set FALL_API_KEY or pass --key")

    root = Path(a.folder).expanduser()
    imgs = sorted(p for p in root.rglob("*") if p.suffix.lower() in EXTS and "results_" not in str(p.parent))
    if not imgs:
        sys.exit(f"no images in {root}")
    run_started = datetime.now()
    run_id = run_started.strftime("%Y%m%d_%H%M%S_%f")
    out = root / f"results_{run_id}"
    out.mkdir()
    history_path = root / "evaluation_history.jsonl"

    table = {}
    if (root / "labels.csv").exists():
        with open(root / "labels.csv") as f:
            for r in csv.reader(f):
                if len(r) >= 2 and norm_label(r[1]):
                    table[r[0].strip()] = norm_label(r[1])

    print(f"{len(imgs)} images → {a.url}/classify")
    results = [None] * len(imgs)
    with history_path.open("a", encoding="utf-8") as history, ThreadPoolExecutor(a.workers) as ex:
        futs = {ex.submit(classify, a.url, a.key, p, a.force, a.model, a.max_side): i for i, p in enumerate(imgs)}
        for k, f in enumerate(as_completed(futs), 1):
            i = futs[f]
            results[i] = f.result()
            r = results[i]
            rel = str(imgs[i].relative_to(root))
            row = row_of(rel, find_label(imgs[i], root, table), r)
            history_record = {
                **row,
                "run_id": run_id,
                "recorded_at": datetime.now().isoformat(timespec="milliseconds"),
                "url": a.url,
                "force": a.force,
                "max_side_upload": a.max_side,
                "model": row["model"] or a.model or "(server default)",
                "response": r,
            }
            history.write(json.dumps(history_record, ensure_ascii=False) + "\n")
            history.flush()
            os.fsync(history.fileno())
            print(f"  [{k}/{len(imgs)}] {imgs[i].name}: {(r.get('vision') or {}).get('on_ground', '-')} "
                  f"{r['latency_total_ms']} ms {r.get('error') or ''}"[:160], flush=True)

    rows = []
    with open(out / "predictions.jsonl", "w") as fj:
        for p, res in zip(imgs, results):
            rel = str(p.relative_to(root))
            row = row_of(rel, find_label(p, root, table), res)
            rows.append(row)
            fj.write(json.dumps({"image": rel, "label": row["label"], **res}, ensure_ascii=False) + "\n")
            print(f"  {rel:40s} label={row['label'] or '-':11s} on_ground={row['pred_on_ground']:9s} "
                  f"conf={row['confidence']}  {row['error'][:60]}")
    with open(out / "predictions.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        w.writerows(rows)

    lat = lambda k: [r[k] for r in rows if isinstance(r[k], int)]
    model_row = next((r for r in rows if r["model"]), {})
    summary = {
        "run": {"date": run_started.isoformat(timespec="seconds"), "run_id": run_id,
                "url": a.url, "force": a.force,
                "model": model_row.get("model") or a.model or "(server default)",
                "max_side_upload": a.max_side, "prompt_version": model_row.get("prompt_version"),
                "folder": str(root)},
        "n_images": len(rows),
        "n_sent_to_model": sum(r["sent_to_model"] is True for r in rows),
        "n_quality_rejected": sum(r["sent_to_model"] is False for r in rows),
        "n_errors": sum(bool(r["error"]) for r in rows),
        "pred_counts": {k: sum(r["pred_on_ground"] == k for r in rows) for k in ("yes", "no", "uncertain")},
        "metrics": metrics(rows),
        "latency_ms": {k: {"median": statistics.median(lat(k)) if lat(k) else None, "p95": pct(lat(k), 0.95)}
                       for k in ("latency_preprocess_ms", "latency_model_ms", "latency_server_ms", "latency_total_ms")},
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    write_md(out / "summary.md", summary)
    history = load_history(history_path)
    comparison = {
        "updated_at": datetime.now().isoformat(timespec="seconds"),
        "history_file": history_path.name,
        "models": model_comparison(history),
    }
    (root / "model_comparison.json").write_text(json.dumps(comparison, indent=2))
    comparison_md = root / "model_comparison.md"
    write_model_comparison(
        comparison_md, comparison["models"], comparison["updated_at"], history_path.name,
    )
    print(f"\nresults → {out}")
    print(f"call history → {history_path}")
    print(f"model comparison → {root / 'model_comparison.json'}")
    print(f"model comparison table → {comparison_md}")
    print((out / "summary.md").read_text())


if __name__ == "__main__":
    main()
