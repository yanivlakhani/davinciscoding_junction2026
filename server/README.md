# davinciscoding_junction2026

## Frame selection for `/analyze`

Send 1-7 JPEG frames in chronological order. The optional multipart field
`best_n` (1-7, default 7) selects up to N usable frames with the highest
sharpness. Unusable frames are still rejected. Selected frames are sent to
Claude in their original chronological order, preserving timestamps inferred
from `duration_s` and the original frame positions.

The response includes `best_n`, `n_frames`, `selected_frame_indices` (zero-based)
and `selected_frame_times_s`. The iOS client accepts `bestN`, defaulting to 7.

## Confrontare modelli di visione

`eval_images.py` permette di confrontare i modelli Claude configurati nel backend.
Esegui il comando sullo stesso dataset etichettato, selezionando un modello alla volta:

```bash
python3 eval_images.py /percorso/al/dataset --model claude-sonnet-5-5
python3 eval_images.py /percorso/al/dataset --model claude-haiku-5-5
python3 eval_images.py /percorso/al/dataset --model claude-opus-5-5
```

Le chiamate vengono aggiunte a `evaluation_history.jsonl`. Lo script aggiorna
`model_comparison.json` e `model_comparison.md` nella cartella del dataset; la
tabella Markdown confronta accuratezza, precisione, recall, specificità, F1,
ROC-AUC e latenza mediana/p95 tra i soli modelli Claude. Le metriche di qualità
sono calcolate solo per le immagini con etichetta ground truth.
