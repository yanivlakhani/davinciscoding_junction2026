# Model comparison

- Updated: 2026-11-14T20:52:40
- Call history: `evaluation_history.jsonl`

| Model | Prompt | Calls | Sent | Errors | Accuracy | Precision | Recall | Specificity | F1 | ROC-AUC | Latency median ms | Latency p95 ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude-haiku-5-5 | v3-caduta-it | 84 | 84 | 12 | n/a | n/a | n/a | n/a | n/a | n/a | 1316.0 | 2104 |
| claude-sonnet-5-5 | v3-caduta-it | 84 | 84 | 0 | n/a | n/a | n/a | n/a | n/a | n/a | 2079.0 | 5268 |

Quality metrics require ground-truth labels. Latency columns report model-call time.
Uncertain predictions are excluded from the standard accuracy/precision/recall/F1 metrics.
For safety-aware recall and accuracy, see `model_comparison.json`.
