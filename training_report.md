# Report unico: addestramento e confronto XGBoost

Aggiornamento: 2026-11-14T12:32:57.663985+02:00. Questo documento sostituisce il precedente report.
Fonte corrente per il paper: risultati ricalcolati sui dati originali, non numeri stimati.
Le nuove informazioni rilevanti e le relative descrizioni vanno mantenute in questo file.

## 1. Sintesi del confronto

Completo: 200 alberi, 38 feature, post-impatto 1,5 s. Leggero: 100 alberi, 25 feature, post-impatto 1,0 s. Entrambi depth=3.
Il confronto modifica contemporaneamente alberi, feature e finestra: non isola l'effetto causale di una singola ottimizzazione.

### Metriche OOF alla soglia fissa 0,5

| Modello | Accuracy % | Precision % | Recall candidati % | F1 % | Specificita % | Balanced accuracy % | MCC |
|---|---:|---:|---:|---:|---:|---:|---:|
| completo | 89.58 | 73.68 | 100.00 | 84.85 | 85.29 | 92.65 | 0.7928 |
| leggero | 87.50 | 72.22 | 92.86 | 81.25 | 85.29 | 89.08 | 0.7337 |

| Modello | TP | FP | TN | FN | Cadute trovate | Recall eventi % | FA/min | ROC-AUC | PR-AUC | AP |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| completo | 14 | 5 | 29 | 0 | 14/15 | 93.33 | 0.6717 | 0.9727 | 0.9318 | 0.9344 |
| leggero | 13 | 5 | 29 | 1 | 13/15 | 86.67 | 0.6717 | 0.9097 | 0.8898 | 0.8932 |

### Tempo di esecuzione e dimensioni

Tempi Python sul computer indicato sotto, NON sul telefono. 1000 finestre reali ripetute con seed 42, 30 warm-up, batch=1. Il tempo predict include il wrapper sklearn/XGBoost e la conversione della matrice.

| Modello | Estrazione media ms | Predict medio ms | Totale medio ms | Mediana ms | P95 ms | JSON KiB | Attesa post + media calcolo ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| completo | 0.154416 | 0.071949 | 0.226365 | 0.212021 | 0.310409 | 136.17 | 1500.226365 |
| leggero | 0.117012 | 0.080928 | 0.197940 | 0.162750 | 0.489494 | 80.91 | 1000.197940 |

Speedup medio leggero vs completo per estrazione+predict: 1.144x.
P95 = valore sotto cui cade il 95% delle 1000 misure; non e un worst-case garantito.
I tempi dipendono da host, carico e runtime: variazioni tra esecuzioni sono normali.
Attesa post + calcolo assume un impatto gia localizzato. NMS globale e ricentraggio +/-3 s sono offline: NON e la latenza end-to-end di un detector su telefono.

### Tempo di training

| Modello | Training fold medio s | Fold std s (ddof=0) | Fit finale baseline s | Selezione+refit finale s | Augmentation finale s | Training finale totale s |
|---|---:|---:|---:|---:|---:|---:|
| completo | 0.276463 | 0.019970 | 0.043303 | 0.000061 | 0.239187 | 0.282551 |
| leggero | 0.279061 | 0.010020 | 0.031300 | 0.022924 | 0.245950 | 0.300174 |

Training fold include augmentation, estrazione/matrice e fit; esclude caricamento, ricampionamento e segmentazione iniziali. Il leggero include un primo fit a 100 alberi/38 feature per la selezione, poi il refit a 25. I tempi finali sono una singola misura.

### Soglia calibrata a zero falsi allarmi OOF

| Modello | Soglia >= | Accuracy % | Precision % | Recall candidati % | F1 % | Cadute trovate | FA/min |
|---|---:|---:|---:|---:|---:|---:|---:|
| completo | 0.93913978338241577 | 87.50 | 100.00 | 57.14 | 72.73 | 8/15 | 0.0000 |
| leggero | 0.96122926473617554 | 83.33 | 100.00 | 42.86 | 60.00 | 6/15 | 0.0000 |

Soglia = successivo Float32 sopra il massimo negativo OOF. Calibrata e valutata sugli stessi OOF: risultato descrittivo, non indipendente e non garanzia di zero FA futuri. I JSON XGBoost non incorporano la soglia operativa: applicarla esternamente.

## 2. Dataset e protocollo

- 17 sessioni, 15 con cadute, 2 senza; 15 eventi annotati.
- 15322 campioni ricampionati a 30 Hz; somma durate delle griglie 510.166667 s.
- Tempo fuori falling dai timestamp originali: 7.4435685175 min.
- 48 candidati valutati: 14 positivi, 34 negativi. Una caduta senza candidato valido resta nel totale eventi.
- Dati di un soggetto, cadute simulate su materasso: informazioni dichiarate dall'utente, non dedotte dai CSV. Modello esatto del dispositivo, eta/salute e procedura di annotazione: [DA COMPLETARE]. La mappatura camminata/scale per sessione non e verificata.
- Sensori: accelerometro XYZ in m/s^2 con gravita, gyro XYZ in rad/s; magnetometro/quaternione esclusi. X laterale, Y verticale in piedi, Z avanti/indietro.
- Timestamp_ns interi prima della conversione; interpolazione lineare a 30 Hz, replica ai bordi e per finestre incomplete. Nessuna modifica ai CSV originali.
- Un tratto contiguo falling=1 = un evento. Candidati da massimi |a|>15 oppure minimi |a|<0,6g, g=9,80665; NMS globale a distanza 1 s con priorita abs(|a|-g).
- Un positivo per evento entro +/-0,3 s dal picco annotato. Negativi fuori falling +/-1 s; ambigui scartati. Positivi ricentrati sull'argmax di segment_fall entro +/-3 s.
- LOSO: 17 fold, 16 sessioni train/1 test; stessi split nei due modelli. Nessuno split casuale di finestre; nessuna sessione test tra i donatori.
- Metriche aggregate sulle predizioni out-of-fold, non medie per fold e non training accuracy.
- Top25 selezionate con gain sul solo training di ciascun fold; ordine originale stabile per i pari merito. Selezione finale su tutti i dati solo dopo la valutazione.

## 3. Modello, augmentation e feature

- Parametri comuni: max_depth=3, learning_rate=0.05, subsample=0.8, colsample_bytree=0.8, base_score=0.5, hist, binary:logistic, logloss, n_jobs=1, seed=42.
- scale_pos_weight = negativi/positivi del training aumentato; sample_weight=1 reali, 0.4 sintetici.
- Per positivo: 15 trasformazioni + 15 ricombinazioni; per negativo: 1 trasformazione, 1 negativo urto, 1 negativo gyro. Reali e sintetici separati con origine e donatori.
- Rotazione condivisa acc/gyro +/-15 gradi; scala dinamica acc e gyro +/-20%, gravita passa-basso 0.3 Hz invariata rispetto alla scala; warp +/-10% con compensazione urto; shift +/-0.3 s; rumore sigma acc=0.15 e gyro=0.03; drop fino al 10% e reinterpolazione.
- Specchio su meta copie positive: acc x invertita; gyro y/z invertiti. Ricombinazioni da 3 sessioni train distinte, crossfade 0.3 s e allineamento post.
- Negativi difficili: non-falling + solo urto senza cambio sistematico inclinazione; non-falling con gyro x1.5-2 senza picchi acc. Non-falling e proxy, non camminata verificata.
- Training finale: 48 reali + 522 sintetici = 570; 434 positivi, 136 negativi. Nessuna augmentation nel test; solo training dopo lo split.
- Feature semplici; std ddof=0, nessuna FFT. Pre 45 campioni; post 46 completo/31 leggero. Le finestre includono centro e ultimo estremo nel post. Input leggero 76x6, completo 91x6.

### Formule e unita di tutte le feature

a=sqrt(ax^2+ay^2+az^2), omega=sqrt(gx^2+gy^2+gz^2); angle(u,v)=acos(clamp(dot(u,v)/(norm(u)*norm(v)),-1,1))*180/pi. Argmin/argmax indicano la prima occorrenza. Angoli da accelerazione media sono proxy di gravita.

| Feature | Formula | Unita |
|---|---|---|
| pre_a_max | `max(a)` | m/s^2 |
| pre_a_min | `min(a)` | m/s^2 |
| pre_a_mean | `mean(a)` | m/s^2 |
| pre_a_std | `sqrt(mean((a-mean(a))^2)); ddof=0` | m/s^2 |
| pre_a_range | `max(a)-min(a)` | m/s^2 |
| pre_jerk_max | `30*max(abs(a[i+1]-a[i]))` | m/s^3 |
| pre_low_g_count | `sum(a < 0.6*9.80665)` | samples |
| pre_min_to_max_s | `(first_argmax(a)-first_argmin(a))/30; signed` | s |
| pre_ax_mean | `mean(ax)` | m/s^2 |
| pre_ax_std | `sqrt(mean((ax-mean(ax))^2)); ddof=0` | m/s^2 |
| pre_ay_mean | `mean(ay)` | m/s^2 |
| pre_ay_std | `sqrt(mean((ay-mean(ay))^2)); ddof=0` | m/s^2 |
| pre_az_mean | `mean(az)` | m/s^2 |
| pre_az_std | `sqrt(mean((az-mean(az))^2)); ddof=0` | m/s^2 |
| pre_omega_max | `max(omega)` | rad/s |
| pre_omega_mean | `mean(omega)` | rad/s |
| pre_rotation_rad | `sum(omega)/30; rectangular sum` | rad |
| post_a_max | `max(a)` | m/s^2 |
| post_a_min | `min(a)` | m/s^2 |
| post_a_mean | `mean(a)` | m/s^2 |
| post_a_std | `sqrt(mean((a-mean(a))^2)); ddof=0` | m/s^2 |
| post_a_range | `max(a)-min(a)` | m/s^2 |
| post_jerk_max | `30*max(abs(a[i+1]-a[i]))` | m/s^3 |
| post_low_g_count | `sum(a < 0.6*9.80665)` | samples |
| post_min_to_max_s | `(first_argmax(a)-first_argmin(a))/30; signed` | s |
| post_ax_mean | `mean(ax)` | m/s^2 |
| post_ax_std | `sqrt(mean((ax-mean(ax))^2)); ddof=0` | m/s^2 |
| post_ay_mean | `mean(ay)` | m/s^2 |
| post_ay_std | `sqrt(mean((ay-mean(ay))^2)); ddof=0` | m/s^2 |
| post_az_mean | `mean(az)` | m/s^2 |
| post_az_std | `sqrt(mean((az-mean(az))^2)); ddof=0` | m/s^2 |
| post_omega_max | `max(omega)` | rad/s |
| post_omega_mean | `mean(omega)` | rad/s |
| post_rotation_rad | `sum(omega)/30; rectangular sum` | rad |
| gravity_pre_post_deg | `angle(mean(acc[15:45]), mean(acc[-30:]))` | deg |
| gravity_post_y_deg | `angle(mean(acc[-30:]), [0,1,0])` | deg |
| last_second_a_std | `sqrt(mean((a[-30:]-mean(a[-30:]))^2)); ddof=0` | m/s^2 |
| last_second_omega_mean | `mean(omega[-30:])` | rad/s |

### Ordine input finale: completo

`pre_a_max`, `pre_a_min`, `pre_a_mean`, `pre_a_std`, `pre_a_range`, `pre_jerk_max`, `pre_low_g_count`, `pre_min_to_max_s`, `pre_ax_mean`, `pre_ax_std`, `pre_ay_mean`, `pre_ay_std`, `pre_az_mean`, `pre_az_std`, `pre_omega_max`, `pre_omega_mean`, `pre_rotation_rad`, `post_a_max`, `post_a_min`, `post_a_mean`, `post_a_std`, `post_a_range`, `post_jerk_max`, `post_low_g_count`, `post_min_to_max_s`, `post_ax_mean`, `post_ax_std`, `post_ay_mean`, `post_ay_std`, `post_az_mean`, `post_az_std`, `post_omega_max`, `post_omega_mean`, `post_rotation_rad`, `gravity_pre_post_deg`, `gravity_post_y_deg`, `last_second_a_std`, `last_second_omega_mean`

Modello: `/Users/eddi/Desktop/JUNCTION/models/comparison/completo_model.json`.
SHA-256: `0817d9dbfe1cc95f4f979f0ede3ba43e49a6cfb6aed0040a5d4bf62a902e3945`.
Importanza gain del modello finale (descrittiva, non test indipendente):

| Feature | Gain normalizzato |
|---|---:|
| post_ay_mean | 0.229441 |
| gravity_post_y_deg | 0.155854 |
| post_low_g_count | 0.123561 |
| last_second_a_std | 0.090606 |
| gravity_pre_post_deg | 0.072422 |
| pre_az_std | 0.034721 |
| pre_omega_max | 0.033743 |
| pre_low_g_count | 0.031289 |
| post_az_std | 0.024682 |
| post_az_mean | 0.021698 |
| pre_a_min | 0.021174 |
| post_ay_std | 0.016457 |
| post_omega_mean | 0.013881 |
| last_second_omega_mean | 0.013768 |
| pre_az_mean | 0.013209 |
| pre_a_range | 0.012413 |
| post_a_range | 0.011074 |
| pre_a_mean | 0.009450 |
| pre_a_std | 0.009402 |
| pre_omega_mean | 0.008642 |
| post_a_max | 0.008531 |
| pre_ay_mean | 0.007689 |
| pre_ax_std | 0.006722 |
| pre_jerk_max | 0.006514 |
| post_omega_max | 0.006393 |
| post_a_mean | 0.005360 |
| post_min_to_max_s | 0.005261 |
| post_a_std | 0.003242 |
| post_a_min | 0.002801 |
| pre_a_max | 0.000000 |
| pre_min_to_max_s | 0.000000 |
| pre_ax_mean | 0.000000 |
| pre_ay_std | 0.000000 |
| pre_rotation_rad | 0.000000 |
| post_jerk_max | 0.000000 |
| post_ax_mean | 0.000000 |
| post_ax_std | 0.000000 |
| post_rotation_rad | 0.000000 |

### Ordine input finale: leggero

`pre_a_min`, `pre_a_std`, `pre_a_range`, `pre_low_g_count`, `pre_min_to_max_s`, `pre_ax_mean`, `pre_ax_std`, `pre_ay_mean`, `pre_az_mean`, `pre_az_std`, `pre_omega_max`, `pre_omega_mean`, `pre_rotation_rad`, `post_a_max`, `post_a_min`, `post_a_mean`, `post_low_g_count`, `post_ax_mean`, `post_ay_mean`, `post_ay_std`, `post_az_mean`, `post_az_std`, `post_omega_mean`, `gravity_pre_post_deg`, `gravity_post_y_deg`

Modello: `/Users/eddi/Desktop/JUNCTION/models/comparison/leggero_model.json`.
SHA-256: `a9d7f2910049fcc644c5dc11f476dc49f1b31c01db7da0681ab87b68d8ad55fd`.
Importanza gain del modello finale (descrittiva, non test indipendente):

| Feature | Gain normalizzato |
|---|---:|
| gravity_pre_post_deg | 0.169271 |
| post_ay_mean | 0.131602 |
| pre_az_std | 0.101890 |
| gravity_post_y_deg | 0.066259 |
| post_az_mean | 0.065694 |
| pre_omega_max | 0.059173 |
| post_a_max | 0.055695 |
| post_low_g_count | 0.041712 |
| post_a_mean | 0.036877 |
| pre_az_mean | 0.034226 |
| post_ay_std | 0.026478 |
| pre_a_min | 0.022503 |
| post_ax_mean | 0.021903 |
| post_az_std | 0.020908 |
| post_omega_mean | 0.018564 |
| pre_a_range | 0.018527 |
| pre_low_g_count | 0.018154 |
| pre_a_std | 0.017944 |
| post_a_min | 0.017195 |
| pre_omega_mean | 0.016652 |
| pre_min_to_max_s | 0.014774 |
| pre_ax_std | 0.012352 |
| pre_ax_mean | 0.011647 |
| pre_ay_mean | 0.000000 |
| pre_rotation_rad | 0.000000 |

## 4. Definizioni delle metriche

- TP: candidato caduta correttamente segnalato; FN: candidato caduta perso. FP: candidato negativo segnalato; TN: negativo correttamente respinto.
- Accuracy=(TP+TN)/N: quota corretta sui candidati valutati, NON sui campioni IMU.
- Precision=TP/(TP+FP): frazione delle segnalazioni che sono positive.
- Recall candidati=TP/(TP+FN); specificita=TN/(TN+FP).
- F1=2TP/(2TP+FP+FN); balanced accuracy=(recall+specificita)/2.
- MCC=(TP*TN-FP*FN)/sqrt((TP+FP)(TP+FN)(TN+FP)(TN+FN)).
- Event recall=cadute trovate/tutte le cadute, incluse quelle senza candidato. Non confonderlo con recall candidati: denominatori diversi (15 e 14).
- FA/min=FP/minuti fuori falling. La durata include le fasce di esclusione +/-1s mentre i candidati ambigui esclusi non sono valutati: possibile sottostima rispetto allo streaming continuo.
- ROC-AUC: area sotto sensibilita vs tasso falsi positivi al variare della soglia. PR-AUC: integrale trapezoidale precision-recall. AP: average precision, integrazione a gradini; non intercambiabile con PR-AUC. Non sono percentuali di accuracy.
- Le confusion matrix hanno righe reale [0,1], colonne predetto [0,1], cioe [[TN,FP],[FN,TP]].

## 5. Informazioni gia acquisite e limiti

- Piccolo dataset, un soggetto dichiarato, cadute simulate: LOSO non e validazione inter-soggetto o su cadute reali. Nessun test esterno, intervallo di confidenza o significativita dimostrata.
- La localizzazione delle finestre positive usa annotazioni e ricentraggio offline; un massimo +/-3s puo cadere fuori falling. Prestazioni non end-to-end/causali.
- Ricampionamento 30 Hz non ricrea gli urti persi tra campioni; augmentation non crea nuovi soggetti.
- segment_fall esporta fasi e metriche in fall_segments.json: onset da ultima bassa accelerazione <0.6g o gyro>3; end da std(|a|)<0.5 su 0.5s e variazione gravita<5 gradi su 1s, entro +/-3s; got_up da ritorno a +Y entro30 gradi dopo esserne usciti. Assenti=null, non interpolati o inventati.
- estimated_height=0.5*9.81*(impact-onset)^2 e un proxy balistico NON VALIDATO, anche per onset giroscopico; non riportarlo come altezza reale.
- I plot delle fasi sono nelle cartelle delle sessioni; overview in plots_segments/. Nessun plot, JSON segmentazione o dato preesistente modificato da questo confronto.
- Export mobile precedente: m2cgen Java->Kotlin, 25 feature, golden test 10+10. I golden sono test numerici, non prestazioni su test indipendente.
- Questo comando NON aggiorna l'export Kotlin, golden o features.json dell'app: i due modelli del confronto sono separati in models/comparison/; usare l'ordine qui riportato.

## 6. Risultati per sessione (OOF, versione leggera)

| Sessione | Cadute annotate | Candidati positivi | Candidati negativi | Probabilita massima candidati |
|---|---:|---:|---:|---:|
| 00f9211b3a28484fa7140de76a53e27e | 1 | 1 | 0 | 0.97161049 |
| 2defd28308c04bcbb925fd683ca924bc | 1 | 1 | 0 | 0.98177415 |
| 45a239871df34489895cb9c03529720d | 1 | 1 | 0 | 0.95826697 |
| 54521c6308d7413ba93b000ccebc4f0d | 1 | 1 | 1 | 0.95159060 |
| 6f288d3e7f934ecba1fa1257cdf5ad50 | 1 | 1 | 0 | 0.57684690 |
| 71e046e927054d48a993694c5f70fa55 | 0 | 0 | 14 | 0.96122921 |
| 7df5c18d8b104dd0b00e553594a21a1c | 1 | 1 | 0 | 0.92574710 |
| 973d6a171e6744478a837c24aa82bbb4 | 1 | 1 | 0 | 0.98165911 |
| c3ec7abf52bf4397933120cf4781c1b2 | 1 | 0 | 1 | 0.45586416 |
| c4656a10b80447dc91c6735893b53c15 | 1 | 1 | 0 | 0.95436847 |
| cfe78525c20f4c859b789a2ac909c4d6 | 1 | 1 | 1 | 0.96844882 |
| dd1597d3589749678c797210db1bf725 | 1 | 1 | 0 | 0.01244661 |
| e09bd7d7d2a6494fa5069d0f9a3fc0a6 | 0 | 0 | 17 | 0.75598437 |
| eaa0f8ec61584960b18a64a35c915cf9 | 1 | 1 | 0 | 0.92346108 |
| eb64936880cd447a9c20c695f4f90e38 | 1 | 1 | 0 | 0.97799772 |
| ef8ef0ed652e42f4abc1faf58fee525f | 1 | 1 | 0 | 0.98477781 |
| f9396e8b57434eb3b55a39dea110f29e | 1 | 1 | 0 | 0.63063812 |

## 7. Riproduzione e provenienza

Comando: `python3 train_fall.py --compare-models`.
Il comando riallena entrambi i modelli, rigenera le metriche e sostituisce questo report con i risultati correnti. Le informazioni metodologiche sono mantenute nel generatore.
Ambiente: `{"python": "3.13.5", "platform": "macOS-26.6.2-arm64-arm-64bit-Mach-O", "processor": "arm64", "numpy": "2.1.3", "pandas": "2.2.3", "scipy": "1.15.3", "sklearn": "1.6.1", "xgboost": "3.4.1"}`.
SHA-256 script: `3791c6a75a46886d41c72513943a22631c8a8413b5d2942ff5a5b33a1539693a`.
I dettagli sottostanti includono predizioni OOF, metriche non arrotondate, feature per fold, tempi, checksum e feature finali: consentono di verificare le tabelle.

## 8. Dati numerici completi (machine-readable)

```json
{
  "generated_at": "2026-11-14T12:32:57.663985+02:00",
  "environment": {
    "python": "3.13.5",
    "platform": "macOS-26.6.2-arm64-arm-64bit-Mach-O",
    "processor": "arm64",
    "numpy": "2.1.3",
    "pandas": "2.2.3",
    "scipy": "1.15.3",
    "sklearn": "1.6.1",
    "xgboost": "3.4.1"
  },
  "dataset": {
    "sessions": 17,
    "fall_sessions": 15,
    "nonfall_sessions": 2,
    "events": 15,
    "real_candidates": 48,
    "positive_candidates": 14,
    "negative_candidates": 34,
    "nonfall_minutes": 7.4435685175,
    "resampled_samples": 15322,
    "resampled_duration_s": 510.16666666666663
  },
  "models": {
    "completo": {
      "trees": 200,
      "features": 38,
      "post_seconds": 1.5,
      "metrics_0_5": {
        "threshold": 0.5,
        "tp": 14,
        "fp": 5,
        "tn": 29,
        "fn": 0,
        "accuracy": 0.8958333333333334,
        "precision": 0.7368421052631579,
        "recall_candidates": 1.0,
        "specificity": 0.8529411764705882,
        "f1": 0.8484848484848485,
        "balanced_accuracy": 0.9264705882352942,
        "mcc": 0.7927691796079253,
        "roc_auc": 0.9726890756302521,
        "pr_auc": 0.9317671823974346,
        "average_precision": 0.9343624629338915,
        "falls_found": 14,
        "falls_total": 15,
        "recall_events": 0.9333333333333333,
        "false_alarms_per_minute": 0.6717208269454208
      },
      "metrics_zero_fa_oof": {
        "threshold": 0.9391397833824158,
        "tp": 8,
        "fp": 0,
        "tn": 34,
        "fn": 6,
        "accuracy": 0.875,
        "precision": 1.0,
        "recall_candidates": 0.5714285714285714,
        "specificity": 1.0,
        "f1": 0.7272727272727273,
        "balanced_accuracy": 0.7857142857142857,
        "mcc": 0.6969320524371696,
        "roc_auc": 0.9726890756302521,
        "pr_auc": 0.9317671823974346,
        "average_precision": 0.9343624629338915,
        "falls_found": 8,
        "falls_total": 15,
        "recall_events": 0.5333333333333333,
        "false_alarms_per_minute": 0.0
      },
      "benchmark": {
        "iterations": 1000,
        "source": "real resampled windows, repeated with seed 42",
        "feature_mean_ms": 0.15441579499999997,
        "predict_mean_ms": 0.071949417,
        "combined_mean_ms": 0.22636521199999998,
        "combined_median_ms": 0.2120205,
        "combined_p95_ms": 0.3104086499999999,
        "booster_json_kib": 136.1162109375,
        "platform": "Python host, not a phone measurement"
      },
      "folds": [
        {
          "test_session": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "augmentation_and_matrix_s": 0.20295266603352502,
          "baseline_fit_s": 0.06427208398235962,
          "selection_and_refit_s": 8.374976459890604e-06,
          "total_training_s": 0.26723312499234453,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "71e046e927054d48a993694c5f70fa55",
          "augmentation_and_matrix_s": 0.21954229200491682,
          "baseline_fit_s": 0.03683370799990371,
          "selection_and_refit_s": 7.212499622255564e-05,
          "total_training_s": 0.2564481250010431,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "54521c6308d7413ba93b000ccebc4f0d",
          "augmentation_and_matrix_s": 0.2358754170127213,
          "baseline_fit_s": 0.04168370796833187,
          "selection_and_refit_s": 5.858304211869836e-05,
          "total_training_s": 0.27761770802317187,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std"x,
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "cfe78525c20f4c859b789a2ac909c4d6",
          "augmentation_and_matrix_s": 0.22659879201091826,
          "baseline_fit_s": 0.03999133297475055,
          "selection_and_refit_s": 5.6791992392390966e-05,
          "total_training_s": 0.2666469169780612,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "f9396e8b57434eb3b55a39dea110f29e",
          "augmentation_and_matrix_s": 0.24761824996676296,
          "baseline_fit_s": 0.04093254200415686,
          "selection_and_refit_s": 6.287498399615288e-05,
          "total_training_s": 0.28861366695491597,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "7df5c18d8b104dd0b00e553594a21a1c",
          "augmentation_and_matrix_s": 0.23202974995365366,
          "baseline_fit_s": 0.04097408300731331,
          "selection_and_refit_s": 6.991700502112508e-05,
          "total_training_s": 0.2730737499659881,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "2defd28308c04bcbb925fd683ca924bc",
          "augmentation_and_matrix_s": 0.22806449997005984,
          "baseline_fit_s": 0.04189245798625052,
          "selection_and_refit_s": 5.820899968966842e-05,
          "total_training_s": 0.27001516695600003,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "45a239871df34489895cb9c03529720d",
          "augmentation_and_matrix_s": 0.23096837499178946,
          "baseline_fit_s": 0.04251445800764486,
          "selection_and_refit_s": 6.7666987888515e-05,
          "total_training_s": 0.27355049998732284,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "6f288d3e7f934ecba1fa1257cdf5ad50",
          "augmentation_and_matrix_s": 0.22909495903877541,
          "baseline_fit_s": 0.03929570800391957,
          "selection_and_refit_s": 5.879194941371679e-05,
          "total_training_s": 0.2684494589921087,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "c3ec7abf52bf4397933120cf4781c1b2",
          "augmentation_and_matrix_s": 0.23750295798527077,
          "baseline_fit_s": 0.04129195801215246,
          "selection_and_refit_s": 6.979197496548295e-05,
          "total_training_s": 0.2788647079723887,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "973d6a171e6744478a837c24aa82bbb4",
          "augmentation_and_matrix_s": 0.22515087499050424,
          "baseline_fit_s": 0.042066708963830024,
          "selection_and_refit_s": 7.325003389269114e-05,
          "total_training_s": 0.26729083398822695,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "ef8ef0ed652e42f4abc1faf58fee525f",
          "augmentation_and_matrix_s": 0.308373624982778,
          "baseline_fit_s": 0.04307795799104497,
          "selection_and_refit_s": 7.97079992480576e-05,
          "total_training_s": 0.351531290973071,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "c4656a10b80447dc91c6735893b53c15",
          "augmentation_and_matrix_s": 0.22624300001189113,
          "baseline_fit_s": 0.040905583009589463,
          "selection_and_refit_s": 6.295798812061548e-05,
          "total_training_s": 0.2672115410096012,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "dd1597d3589749678c797210db1bf725",
          "augmentation_and_matrix_s": 0.22645037504844368,
          "baseline_fit_s": 0.04066208394942805,
          "selection_and_refit_s": 0.00015904102474451065,
          "total_training_s": 0.26727150002261624,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "eaa0f8ec61584960b18a64a35c915cf9",
          "augmentation_and_matrix_s": 0.2337069580098614,
          "baseline_fit_s": 0.04155745799653232,
          "selection_and_refit_s": 5.862500984221697e-05,
          "total_training_s": 0.27532304101623595,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "eb64936880cd447a9c20c695f4f90e38",
          "augmentation_and_matrix_s": 0.23575345805147663,
          "baseline_fit_s": 0.042991874972358346,
          "selection_and_refit_s": 6.82090176269412e-05,
          "total_training_s": 0.2788135420414619,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "00f9211b3a28484fa7140de76a53e27e",
          "augmentation_and_matrix_s": 0.23167775000911206,
          "baseline_fit_s": 0.04017845797352493,
          "selection_and_refit_s": 5.3750001825392246e-05,
          "total_training_s": 0.2719099579844624,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_jerk_max",
            "post_low_g_count",
            "post_min_to_max_s",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        }
      ],
      "fold_training_examples_min": 502,
      "fold_training_examples_max": 566,
      "final_training": {
        "real_examples": 48,
        "synthetic_examples": 522,
        "positive_examples": 434,
        "negative_examples": 136,
        "augmentation_and_matrix_s": 0.23918704205425456,
        "baseline_fit_s": 0.043302582984324545,
        "selection_and_refit_s": 6.133300485089421e-05,
        "total_training_s": 0.28255095804343
      },
      "model_path": "/Users/eddi/Desktop/JUNCTION/models/comparison/completo_model.json",
      "model_json_kib": 136.1689453125,
      "model_sha256": "0817d9dbfe1cc95f4f979f0ede3ba43e49a6cfb6aed0040a5d4bf62a902e3945",
      "feature_names": [
        "pre_a_max",
        "pre_a_min",
        "pre_a_mean",
        "pre_a_std",
        "pre_a_range",
        "pre_jerk_max",
        "pre_low_g_count",
        "pre_min_to_max_s",
        "pre_ax_mean",
        "pre_ax_std",
        "pre_ay_mean",
        "pre_ay_std",
        "pre_az_mean",
        "pre_az_std",
        "pre_omega_max",
        "pre_omega_mean",
        "pre_rotation_rad",
        "post_a_max",
        "post_a_min",
        "post_a_mean",
        "post_a_std",
        "post_a_range",
        "post_jerk_max",
        "post_low_g_count",
        "post_min_to_max_s",
        "post_ax_mean",
        "post_ax_std",
        "post_ay_mean",
        "post_ay_std",
        "post_az_mean",
        "post_az_std",
        "post_omega_max",
        "post_omega_mean",
        "post_rotation_rad",
        "gravity_pre_post_deg",
        "gravity_post_y_deg",
        "last_second_a_std",
        "last_second_omega_mean"
      ],
      "feature_importance_gain": {
        "pre_a_max": 0.0,
        "pre_a_min": 0.021174080669879913,
        "pre_a_mean": 0.009449646808207035,
        "pre_a_std": 0.009401961229741573,
        "pre_a_range": 0.012413134798407555,
        "pre_jerk_max": 0.00651429733261466,
        "pre_low_g_count": 0.031288955360651016,
        "pre_min_to_max_s": 0.0,
        "pre_ax_mean": 0.0,
        "pre_ax_std": 0.006722203455865383,
        "pre_ay_mean": 0.007688647136092186,
        "pre_ay_std": 0.0,
        "pre_az_mean": 0.013208718970417976,
        "pre_az_std": 0.03472110256552696,
        "pre_omega_max": 0.03374337777495384,
        "pre_omega_mean": 0.008642059750854969,
        "pre_rotation_rad": 0.0,
        "post_a_max": 0.008531277067959309,
        "post_a_min": 0.0028009929228574038,
        "post_a_mean": 0.005360113922506571,
        "post_a_std": 0.003241969970986247,
        "post_a_range": 0.01107429713010788,
        "post_jerk_max": 0.0,
        "post_low_g_count": 0.1235605999827385,
        "post_min_to_max_s": 0.005261064972728491,
        "post_ax_mean": 0.0,
        "post_ax_std": 0.0,
        "post_ay_mean": 0.22944067418575287,
        "post_ay_std": 0.016457419842481613,
        "post_az_mean": 0.02169831655919552,
        "post_az_std": 0.024681584909558296,
        "post_omega_max": 0.006393098272383213,
        "post_omega_mean": 0.013880783692002296,
        "post_rotation_rad": 0.0,
        "gravity_pre_post_deg": 0.07242152094841003,
        "gravity_post_y_deg": 0.15585362911224365,
        "last_second_a_std": 0.09060624241828918,
        "last_second_omega_mean": 0.01376831904053688
      },
      "oof_predictions": [
        {
          "index": 0,
          "session_id": "00f9211b3a28484fa7140de76a53e27e",
          "label": 1,
          "event_id": "00f9211b3a28484fa7140de76a53e27e:0",
          "probability": 0.9906107783317566
        },
        {
          "index": 1,
          "session_id": "2defd28308c04bcbb925fd683ca924bc",
          "label": 1,
          "event_id": "2defd28308c04bcbb925fd683ca924bc:0",
          "probability": 0.9930092096328735
        },
        {
          "index": 2,
          "session_id": "45a239871df34489895cb9c03529720d",
          "label": 1,
          "event_id": "45a239871df34489895cb9c03529720d:0",
          "probability": 0.9620741009712219
        },
        {
          "index": 3,
          "session_id": "54521c6308d7413ba93b000ccebc4f0d",
          "label": 1,
          "event_id": "54521c6308d7413ba93b000ccebc4f0d:0",
          "probability": 0.9786595702171326
        },
        {
          "index": 4,
          "session_id": "54521c6308d7413ba93b000ccebc4f0d",
          "label": 0,
          "event_id": "",
          "probability": 0.3709385097026825
        },
        {
          "index": 5,
          "session_id": "6f288d3e7f934ecba1fa1257cdf5ad50",
          "label": 1,
          "event_id": "6f288d3e7f934ecba1fa1257cdf5ad50:0",
          "probability": 0.8968302011489868
        },
        {
          "index": 6,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.035625703632831573
        },
        {
          "index": 7,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.932780385017395
        },
        {
          "index": 8,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.14057348668575287
        },
        {
          "index": 9,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.11758505553007126
        },
        {
          "index": 10,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.05769677460193634
        },
        {
          "index": 11,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.02465210296213627
        },
        {
          "index": 12,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.15638664364814758
        },
        {
          "index": 13,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.03717990592122078
        },
        {
          "index": 14,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.04692941904067993
        },
        {
          "index": 15,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.018480099737644196
        },
        {
          "index": 16,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.015401662327349186
        },
        {
          "index": 17,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.7672184109687805
        },
        {
          "index": 18,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.11796300858259201
        },
        {
          "index": 19,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.28337863087654114
        },
        {
          "index": 20,
          "session_id": "7df5c18d8b104dd0b00e553594a21a1c",
          "label": 1,
          "event_id": "7df5c18d8b104dd0b00e553594a21a1c:0",
          "probability": 0.8877214193344116
        },
        {
          "index": 21,
          "session_id": "973d6a171e6744478a837c24aa82bbb4",
          "label": 1,
          "event_id": "973d6a171e6744478a837c24aa82bbb4:0",
          "probability": 0.9943640232086182
        },
        {
          "index": 22,
          "session_id": "c3ec7abf52bf4397933120cf4781c1b2",
          "label": 0,
          "event_id": "",
          "probability": 0.939139723777771
        },
        {
          "index": 23,
          "session_id": "c4656a10b80447dc91c6735893b53c15",
          "label": 1,
          "event_id": "c4656a10b80447dc91c6735893b53c15:0",
          "probability": 0.9858201742172241
        },
        {
          "index": 24,
          "session_id": "cfe78525c20f4c859b789a2ac909c4d6",
          "label": 1,
          "event_id": "cfe78525c20f4c859b789a2ac909c4d6:0",
          "probability": 0.8573513031005859
        },
        {
          "index": 25,
          "session_id": "cfe78525c20f4c859b789a2ac909c4d6",
          "label": 0,
          "event_id": "",
          "probability": 0.007344188634306192
        },
        {
          "index": 26,
          "session_id": "dd1597d3589749678c797210db1bf725",
          "label": 1,
          "event_id": "dd1597d3589749678c797210db1bf725:0",
          "probability": 0.6544765830039978
        },
        {
          "index": 27,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.3797551691532135
        },
        {
          "index": 28,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.26709720492362976
        },
        {
          "index": 29,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.01613175868988037
        },
        {
          "index": 30,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.3204813003540039
        },
        {
          "index": 31,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.020076924934983253
        },
        {
          "index": 32,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.1202908307313919
        },
        {
          "index": 33,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.5405266880989075
        },
        {
          "index": 34,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.14733918011188507
        },
        {
          "index": 35,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.030312813818454742
        },
        {
          "index": 36,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.2986345589160919
        },
        {
          "index": 37,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.3794538676738739
        },
        {
          "index": 38,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.11942372471094131
        },
        {
          "index": 39,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.037644628435373306
        },
        {
          "index": 40,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.7211881279945374
        },
        {
          "index": 41,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.00728770112618804
        },
        {
          "index": 42,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.039224278181791306
        },
        {
          "index": 43,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.029149482026696205
        },
        {
          "index": 44,
          "session_id": "eaa0f8ec61584960b18a64a35c915cf9",
          "label": 1,
          "event_id": "eaa0f8ec61584960b18a64a35c915cf9:0",
          "probability": 0.9377579689025879
        },
        {
          "index": 45,
          "session_id": "eb64936880cd447a9c20c695f4f90e38",
          "label": 1,
          "event_id": "eb64936880cd447a9c20c695f4f90e38:0",
          "probability": 0.9749011397361755
        },
        {
          "index": 46,
          "session_id": "ef8ef0ed652e42f4abc1faf58fee525f",
          "label": 1,
          "event_id": "ef8ef0ed652e42f4abc1faf58fee525f:0",
          "probability": 0.9935466647148132
        },
        {
          "index": 47,
          "session_id": "f9396e8b57434eb3b55a39dea110f29e",
          "label": 1,
          "event_id": "f9396e8b57434eb3b55a39dea110f29e:0",
          "probability": 0.829789936542511
        }
      ]
    },
    "leggero": {
      "trees": 100,
      "features": 25,
      "post_seconds": 1.0,
      "metrics_0_5": {
        "threshold": 0.5,
        "tp": 13,
        "fp": 5,
        "tn": 29,
        "fn": 1,
        "accuracy": 0.875,
        "precision": 0.7222222222222222,
        "recall_candidates": 0.9285714285714286,
        "specificity": 0.8529411764705882,
        "f1": 0.8125,
        "balanced_accuracy": 0.8907563025210083,
        "mcc": 0.7337406559132839,
        "roc_auc": 0.9096638655462185,
        "pr_auc": 0.8898263485079595,
        "average_precision": 0.8932230467944754,
        "falls_found": 13,
        "falls_total": 15,
        "recall_events": 0.8666666666666667,
        "false_alarms_per_minute": 0.6717208269454208
      },
      "metrics_zero_fa_oof": {
        "threshold": 0.9612292647361755,
        "tp": 6,
        "fp": 0,
        "tn": 34,
        "fn": 8,
        "accuracy": 0.8333333333333334,
        "precision": 1.0,
        "recall_candidates": 0.42857142857142855,
        "specificity": 1.0,
        "f1": 0.6,
        "balanced_accuracy": 0.7142857142857143,
        "mcc": 0.5890150893739515,
        "roc_auc": 0.9096638655462185,
        "pr_auc": 0.8898263485079595,
        "average_precision": 0.8932230467944754,
        "falls_found": 6,
        "falls_total": 15,
        "recall_events": 0.4,
        "false_alarms_per_minute": 0.0
      },
      "benchmark": {
        "iterations": 1000,
        "source": "real resampled windows, repeated with seed 42",
        "feature_mean_ms": 0.11701162199999998,
        "predict_mean_ms": 0.080927887,
        "combined_mean_ms": 0.197939509,
        "combined_median_ms": 0.16275,
        "combined_p95_ms": 0.4894937499999997,
        "booster_json_kib": 80.8564453125,
        "platform": "Python host, not a phone measurement"
      },
      "folds": [
        {
          "test_session": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "augmentation_and_matrix_s": 0.21678670804249123,
          "baseline_fit_s": 0.024050834006629884,
          "selection_and_refit_s": 0.017173125001136214,
          "total_training_s": 0.2580106670502573,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "71e046e927054d48a993694c5f70fa55",
          "augmentation_and_matrix_s": 0.21429850003914908,
          "baseline_fit_s": 0.02405658399220556,
          "selection_and_refit_s": 0.018121125001925975,
          "total_training_s": 0.2564762090332806,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_low_g_count",
            "pre_ax_std",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_mean",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_jerk_max",
            "post_low_g_count",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "54521c6308d7413ba93b000ccebc4f0d",
          "augmentation_and_matrix_s": 0.22653458296554163,
          "baseline_fit_s": 0.028923667035996914,
          "selection_and_refit_s": 0.020208166970405728,
          "total_training_s": 0.2756664169719443,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std"
          ]
        },
        {
          "test_session": "cfe78525c20f4c859b789a2ac909c4d6",
          "augmentation_and_matrix_s": 0.25142887502443045,
          "baseline_fit_s": 0.02860550000332296,
          "selection_and_refit_s": 0.020179999992251396,
          "total_training_s": 0.3002143750200048,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_jerk_max",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg"
          ]
        },
        {
          "test_session": "f9396e8b57434eb3b55a39dea110f29e",
          "augmentation_and_matrix_s": 0.22856612503528595,
          "baseline_fit_s": 0.029425582964904606,
          "selection_and_refit_s": 0.02186850004363805,
          "total_training_s": 0.2798602080438286,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_low_g_count",
            "pre_ax_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "7df5c18d8b104dd0b00e553594a21a1c",
          "augmentation_and_matrix_s": 0.22754545899806544,
          "baseline_fit_s": 0.029179333010688424,
          "selection_and_refit_s": 0.020471833006013185,
          "total_training_s": 0.27719662501476705,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "2defd28308c04bcbb925fd683ca924bc",
          "augmentation_and_matrix_s": 0.23515204200521111,
          "baseline_fit_s": 0.029881166003178805,
          "selection_and_refit_s": 0.020884791971184313,
          "total_training_s": 0.28591799997957423,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "45a239871df34489895cb9c03529720d",
          "augmentation_and_matrix_s": 0.23095450003165752,
          "baseline_fit_s": 0.030393749999348074,
          "selection_and_refit_s": 0.0218813749961555,
          "total_training_s": 0.2832296250271611,
          "selected_features": [
            "pre_a_min",
            "pre_a_std",
            "pre_a_range",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std"
          ]
        },
        {
          "test_session": "6f288d3e7f934ecba1fa1257cdf5ad50",
          "augmentation_and_matrix_s": 0.22652808396378532,
          "baseline_fit_s": 0.028919916017912328,
          "selection_and_refit_s": 0.019736166985239834,
          "total_training_s": 0.2751841669669375,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_mean",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "c3ec7abf52bf4397933120cf4781c1b2",
          "augmentation_and_matrix_s": 0.23921095801051706,
          "baseline_fit_s": 0.02949091698974371,
          "selection_and_refit_s": 0.02235204103635624,
          "total_training_s": 0.291053916036617,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_std",
            "pre_low_g_count",
            "pre_ay_mean",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_range",
            "post_low_g_count",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "973d6a171e6744478a837c24aa82bbb4",
          "augmentation_and_matrix_s": 0.23496416700072587,
          "baseline_fit_s": 0.029254875029437244,
          "selection_and_refit_s": 0.020643541996832937,
          "total_training_s": 0.28486258402699605,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_a_range",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "ef8ef0ed652e42f4abc1faf58fee525f",
          "augmentation_and_matrix_s": 0.22823599999537691,
          "baseline_fit_s": 0.0289526249980554,
          "selection_and_refit_s": 0.02076062501873821,
          "total_training_s": 0.2779492500121705,
          "selected_features": [
            "pre_a_max",
            "pre_a_min",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ay_mean",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "c4656a10b80447dc91c6735893b53c15",
          "augmentation_and_matrix_s": 0.22735233296407387,
          "baseline_fit_s": 0.02875200001290068,
          "selection_and_refit_s": 0.021389333996921778,
          "total_training_s": 0.2774936669738963,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_min_to_max_s",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_jerk_max",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg"
          ]
        },
        {
          "test_session": "dd1597d3589749678c797210db1bf725",
          "augmentation_and_matrix_s": 0.23071787500521168,
          "baseline_fit_s": 0.027947166992817074,
          "selection_and_refit_s": 0.020154083031229675,
          "total_training_s": 0.27881912502925843,
          "selected_features": [
            "pre_a_min",
            "pre_low_g_count",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_mean",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_omega_mean",
            "post_rotation_rad",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "eaa0f8ec61584960b18a64a35c915cf9",
          "augmentation_and_matrix_s": 0.22617933404399082,
          "baseline_fit_s": 0.02993837499525398,
          "selection_and_refit_s": 0.02183749998221174,
          "total_training_s": 0.27795520902145654,
          "selected_features": [
            "pre_a_min",
            "pre_a_std",
            "pre_low_g_count",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_a_std",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "eb64936880cd447a9c20c695f4f90e38",
          "augmentation_and_matrix_s": 0.234695749997627,
          "baseline_fit_s": 0.0287323750089854,
          "selection_and_refit_s": 0.020942708011716604,
          "total_training_s": 0.284370833018329,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "pre_rotation_rad",
            "post_a_max",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_a_range",
            "post_low_g_count",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg",
            "last_second_omega_mean"
          ]
        },
        {
          "test_session": "00f9211b3a28484fa7140de76a53e27e",
          "augmentation_and_matrix_s": 0.22610099997837096,
          "baseline_fit_s": 0.031222083023749292,
          "selection_and_refit_s": 0.022458583989646286,
          "total_training_s": 0.27978166699176654,
          "selected_features": [
            "pre_a_min",
            "pre_a_mean",
            "pre_a_std",
            "pre_low_g_count",
            "pre_ax_mean",
            "pre_ax_std",
            "pre_ay_std",
            "pre_az_mean",
            "pre_az_std",
            "pre_omega_max",
            "pre_omega_mean",
            "post_a_min",
            "post_a_mean",
            "post_a_std",
            "post_low_g_count",
            "post_ax_mean",
            "post_ax_std",
            "post_ay_mean",
            "post_ay_std",
            "post_az_mean",
            "post_az_std",
            "post_omega_max",
            "post_omega_mean",
            "gravity_pre_post_deg",
            "gravity_post_y_deg"
          ]
        }
      ],
      "fold_training_examples_min": 502,
      "fold_training_examples_max": 566,
      "final_training": {
        "real_examples": 48,
        "synthetic_examples": 522,
        "positive_examples": 434,
        "negative_examples": 136,
        "augmentation_and_matrix_s": 0.24594954098574817,
        "baseline_fit_s": 0.031300334027037024,
        "selection_and_refit_s": 0.022924416000023484,
        "total_training_s": 0.3001742910128087
      },
      "model_path": "/Users/eddi/Desktop/JUNCTION/models/comparison/leggero_model.json",
      "model_json_kib": 80.9091796875,
      "model_sha256": "a9d7f2910049fcc644c5dc11f476dc49f1b31c01db7da0681ab87b68d8ad55fd",
      "feature_names": [
        "pre_a_min",
        "pre_a_std",
        "pre_a_range",
        "pre_low_g_count",
        "pre_min_to_max_s",
        "pre_ax_mean",
        "pre_ax_std",
        "pre_ay_mean",
        "pre_az_mean",
        "pre_az_std",
        "pre_omega_max",
        "pre_omega_mean",
        "pre_rotation_rad",
        "post_a_max",
        "post_a_min",
        "post_a_mean",
        "post_low_g_count",
        "post_ax_mean",
        "post_ay_mean",
        "post_ay_std",
        "post_az_mean",
        "post_az_std",
        "post_omega_mean",
        "gravity_pre_post_deg",
        "gravity_post_y_deg"
      ],
      "feature_importance_gain": {
        "pre_a_min": 0.022502591833472252,
        "pre_a_std": 0.017944343388080597,
        "pre_a_range": 0.01852748915553093,
        "pre_low_g_count": 0.01815382018685341,
        "pre_min_to_max_s": 0.014774303883314133,
        "pre_ax_mean": 0.011647048406302929,
        "pre_ax_std": 0.012351645156741142,
        "pre_ay_mean": 0.0,
        "pre_az_mean": 0.03422566503286362,
        "pre_az_std": 0.10189006477594376,
        "pre_omega_max": 0.059173326939344406,
        "pre_omega_mean": 0.016651887446641922,
        "pre_rotation_rad": 0.0,
        "post_a_max": 0.05569489300251007,
        "post_a_min": 0.017195064574480057,
        "post_a_mean": 0.03687664121389389,
        "post_low_g_count": 0.041711922734975815,
        "post_ax_mean": 0.021902618929743767,
        "post_ay_mean": 0.13160239160060883,
        "post_ay_std": 0.026477666571736336,
        "post_az_mean": 0.0656941682100296,
        "post_az_std": 0.020907873287796974,
        "post_omega_mean": 0.018564030528068542,
        "gravity_pre_post_deg": 0.1692712903022766,
        "gravity_post_y_deg": 0.0662592351436615
      },
      "oof_predictions": [
        {
          "index": 0,
          "session_id": "00f9211b3a28484fa7140de76a53e27e",
          "label": 1,
          "event_id": "00f9211b3a28484fa7140de76a53e27e:0",
          "probability": 0.9716104865074158
        },
        {
          "index": 1,
          "session_id": "2defd28308c04bcbb925fd683ca924bc",
          "label": 1,
          "event_id": "2defd28308c04bcbb925fd683ca924bc:0",
          "probability": 0.9817741513252258
        },
        {
          "index": 2,
          "session_id": "45a239871df34489895cb9c03529720d",
          "label": 1,
          "event_id": "45a239871df34489895cb9c03529720d:0",
          "probability": 0.9582669734954834
        },
        {
          "index": 3,
          "session_id": "54521c6308d7413ba93b000ccebc4f0d",
          "label": 1,
          "event_id": "54521c6308d7413ba93b000ccebc4f0d:0",
          "probability": 0.9515905976295471
        },
        {
          "index": 4,
          "session_id": "54521c6308d7413ba93b000ccebc4f0d",
          "label": 0,
          "event_id": "",
          "probability": 0.4639268219470978
        },
        {
          "index": 5,
          "session_id": "6f288d3e7f934ecba1fa1257cdf5ad50",
          "label": 1,
          "event_id": "6f288d3e7f934ecba1fa1257cdf5ad50:0",
          "probability": 0.5768468976020813
        },
        {
          "index": 6,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.04527350515127182
        },
        {
          "index": 7,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.9612292051315308
        },
        {
          "index": 8,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.289833664894104
        },
        {
          "index": 9,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.3870205581188202
        },
        {
          "index": 10,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.1692369431257248
        },
        {
          "index": 11,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.1312650740146637
        },
        {
          "index": 12,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.5751069784164429
        },
        {
          "index": 13,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.0589178204536438
        },
        {
          "index": 14,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.05126557499170303
        },
        {
          "index": 15,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.15120342373847961
        },
        {
          "index": 16,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.0386975072324276
        },
        {
          "index": 17,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.5705623030662537
        },
        {
          "index": 18,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.20288600027561188
        },
        {
          "index": 19,
          "session_id": "71e046e927054d48a993694c5f70fa55",
          "label": 0,
          "event_id": "",
          "probability": 0.10418020933866501
        },
        {
          "index": 20,
          "session_id": "7df5c18d8b104dd0b00e553594a21a1c",
          "label": 1,
          "event_id": "7df5c18d8b104dd0b00e553594a21a1c:0",
          "probability": 0.9257470965385437
        },
        {
          "index": 21,
          "session_id": "973d6a171e6744478a837c24aa82bbb4",
          "label": 1,
          "event_id": "973d6a171e6744478a837c24aa82bbb4:0",
          "probability": 0.9816591143608093
        },
        {
          "index": 22,
          "session_id": "c3ec7abf52bf4397933120cf4781c1b2",
          "label": 0,
          "event_id": "",
          "probability": 0.45586416125297546
        },
        {
          "index": 23,
          "session_id": "c4656a10b80447dc91c6735893b53c15",
          "label": 1,
          "event_id": "c4656a10b80447dc91c6735893b53c15:0",
          "probability": 0.9543684720993042
        },
        {
          "index": 24,
          "session_id": "cfe78525c20f4c859b789a2ac909c4d6",
          "label": 1,
          "event_id": "cfe78525c20f4c859b789a2ac909c4d6:0",
          "probability": 0.96844881772995
        },
        {
          "index": 25,
          "session_id": "cfe78525c20f4c859b789a2ac909c4d6",
          "label": 0,
          "event_id": "",
          "probability": 0.06379562616348267
        },
        {
          "index": 26,
          "session_id": "dd1597d3589749678c797210db1bf725",
          "label": 1,
          "event_id": "dd1597d3589749678c797210db1bf725:0",
          "probability": 0.01244660560041666
        },
        {
          "index": 27,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.22731396555900574
        },
        {
          "index": 28,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.36880412697792053
        },
        {
          "index": 29,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.25438207387924194
        },
        {
          "index": 30,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.331294983625412
        },
        {
          "index": 31,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.04526578262448311
        },
        {
          "index": 32,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.09484626352787018
        },
        {
          "index": 33,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.5136292576789856
        },
        {
          "index": 34,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.3023323714733124
        },
        {
          "index": 35,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.15974538028240204
        },
        {
          "index": 36,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.29357585310935974
        },
        {
          "index": 37,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.37130069732666016
        },
        {
          "index": 38,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.3302648067474365
        },
        {
          "index": 39,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.22979682683944702
        },
        {
          "index": 40,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.755984365940094
        },
        {
          "index": 41,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.055152490735054016
        },
        {
          "index": 42,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.027554742991924286
        },
        {
          "index": 43,
          "session_id": "e09bd7d7d2a6494fa5069d0f9a3fc0a6",
          "label": 0,
          "event_id": "",
          "probability": 0.047382108867168427
        },
        {
          "index": 44,
          "session_id": "eaa0f8ec61584960b18a64a35c915cf9",
          "label": 1,
          "event_id": "eaa0f8ec61584960b18a64a35c915cf9:0",
          "probability": 0.9234610795974731
        },
        {
          "index": 45,
          "session_id": "eb64936880cd447a9c20c695f4f90e38",
          "label": 1,
          "event_id": "eb64936880cd447a9c20c695f4f90e38:0",
          "probability": 0.9779977202415466
        },
        {
          "index": 46,
          "session_id": "ef8ef0ed652e42f4abc1faf58fee525f",
          "label": 1,
          "event_id": "ef8ef0ed652e42f4abc1faf58fee525f:0",
          "probability": 0.9847778081893921
        },
        {
          "index": 47,
          "session_id": "f9396e8b57434eb3b55a39dea110f29e",
          "label": 1,
          "event_id": "f9396e8b57434eb3b55a39dea110f29e:0",
          "probability": 0.6306381225585938
        }
      ]
    }
  },
  "comparison_runtime_s": 10.561075708945282,
  "training_script_sha256": "3791c6a75a46886d41c72513943a22631c8a8413b5d2942ff5a5b33a1539693a"
}
```

<!-- integration-notes -->
## 9. Collegamento Python ai dati degli occhiali

Aggiornamento integrazione: 14 novembre 2026. Non e stato effettuato un nuovo
training per questo adattatore. Il checksum dello script nella sezione precedente
identifica la versione del confronto, prima dell'aggiunta della conservazione
di queste note nel generatore del report.

### File da usare insieme

- [glasses_fall_inference.py](./glasses_fall_inference.py): adattatore sensori e predizione.
- [train_fall.py](./train_fall.py): implementazione condivisa di `extract_features`,
  formule e ordine delle 38 feature; deve essere importabile accanto all'adattatore.
- [models/comparison/completo_model.json](./models/comparison/completo_model.json):
  parametri appresi del completo, 200 alberi, 38 input, profondita massima 3.
  SHA-256: `0817d9dbfe1cc95f4f979f0ede3ba43e49a6cfb6aed0040a5d4bf62a902e3945`.

XGBoost non ha una matrice di pesi separata: alberi, soglie e foglie appresi
sono contenuti nel JSON. Non usare models/features.json per questo modello:
quel contratto descrive il leggero a 25 feature. Per il completo usare
`glasses_fall_inference.FEATURE_NAMES` e le formule di questo report.

### Mappatura canali

| Valore ricevuto dall'SDK (da collegare) | Argomento Python | Colonna training | Unita e significato |
|---|---|---|---|
| Timestamp del campione sul clock del dispositivo | timestamp_ns | timestamp_ns | intero ns, strettamente crescente |
| Accelerazione laterale | ax | accelerometer_x | m/s^2, include gravita |
| Accelerazione verticale | ay | accelerometer_y | m/s^2, +Y verticale in piedi |
| Accelerazione avanti/indietro | az | accelerometer_z | m/s^2, include gravita |
| Velocita angolare X | gx | gyroscope_x | rad/s |
| Velocita angolare Y | gy | gyroscope_y | rad/s |
| Velocita angolare Z | gz | gyroscope_z | rad/s |

Tutti i canali devono essere sincronizzati e usare lo stesso sistema di assi
del training. Non sottrarre la gravita, non normalizzare e non passare
accelerazioni in g o velocita in gradi/s. I nomi SDK non sono stati verificati:
la mappatura dalla loro API ai sei argomenti spetta all'integrazione.

### Flusso di esecuzione

Durante l'allenamento: CSV -> interpolazione a 30 Hz -> candidati e annotazioni
per etichettare -> finestre -> feature -> augmentation solo training ->
fit XGBoost -> modello salvato.

Durante l'uso: buffer IMU -> interpolazione a 30 Hz -> finestra 91x6 intorno
al candidato fornito -> stesse 38 feature -> `predict_proba` -> soglia.
NON viene avviato un training a ogni campione.

L'adattatore riceve array timestamp/ax/ay/az/gx/gy/gz e il timestamp intero
del candidato (`peak_timestamp_ns`). Ancora la griglia al primo timestamp
del buffer, arrotonda il centro alla griglia a 30 Hz e richiede 1,5 s prima
e dopo. Per buffer scorrevoli mantenere un'origine della griglia stabile.
Non esegue padding silenzioso di finestre incomplete: solleva ValueError,
quindi attendere il post necessario prima della chiamata.

I NaN sensore vengono interpolati come nel training, un canale completamente
mancante e rifiutato. Duplicati, timestamp non ordinati e infiniti sono
rifiutati. Buchi oltre 100 ms emettono un warning per possibile distribuzione
diversa da quella osservata.

```python
from glasses_fall_inference import load_full_model, predict_from_imu

model = load_full_model()  # una sola volta all'avvio

# Array sincronizzati ricevuti dall'SDK; timestamp e picco sullo stesso clock.
result = predict_from_imu(
    model, timestamp_ns, ax, ay, az, gx, gy, gz,
    peak_timestamp_ns=timestamp_urto_ns,
    threshold=0.5,
)
probabilita = result["probability"]
caduta = result["is_fall"]
vettore_input = result["feature_vector"]  # 38 numeri, ordine FEATURE_NAMES
```

Il risultato contiene anche nomi, dizionario delle feature e tempo del centro
relativo all'origine del buffer. La soglia predefinita 0,5 corrisponde al
confronto principale; il punteggio non va interpretato come probabilita clinica
calibrata. Una decisione positiva non e una diagnosi.

Esempio eseguibile sui dati esistenti, senza salvare nuovi dati:

```bash
python3 glasses_fall_inference.py \
  data/00f9211b3a28484fa7140de76a53e27e/motion.csv \
  --peak-time-s 4.166667
```

### Verifiche e limiti dell'integrazione

Verificata uguaglianza esatta con le finestre, tutte le 38 feature e le
predizioni del training su 50 candidati con buffer completo nei dati esistenti.
Verificati rifiuto di input invalidi e CLI. Esempio sopra: punteggio
0,9931738972663879 del modello finale; NON e una nuova misura di accuratezza
out-of-fold, perche il modello ha visto la sessione durante il training.

L'adattatore NON implementa il rilevatore causale dei candidati o un allarme
continuo: il timestamp del candidato e fornito dall'app. Non usa falling,
magnetometro, quaternione o segmentazione annotata per la predizione.
La localizzazione online dell'urto rimane da validare: le metriche LOSO su
finestre localizzate offline non diventano automaticamente metriche streaming.
Le dipendenze Python sono quelle del training: numpy, pandas, scipy,
scikit-learn e xgboost. Non serve m2cgen per eseguire questo adattatore.
