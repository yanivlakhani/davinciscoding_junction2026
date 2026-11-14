import pandas as pd
import numpy as np
import coremltools as ct
from sklearn.metrics import classification_report, confusion_matrix

print("1. Lettura e pulizia del file di test: test_reali.csv ...")
try:
    df = pd.read_csv("test_reali.csv")
except FileNotFoundError:
    print("❌ Errore: file 'test_reali.csv' non trovato. Inseriscilo nella cartella.")
    exit()

if 'label' not in df.columns:
    print("❌ Errore: Manca la colonna 'label' nel CSV di test.")
    exit()

# ================================================================
# 🔥 AUTO-TRIMMER (Stessa logica del training per coerenza) 🔥
# ================================================================
if (df['label'] == 1).any():
    acc_mag = np.sqrt(df['acc_x']**2 + df['acc_y']**2 + df['acc_z']**2)
    mag_in_hold = acc_mag[df['label'] == 1]
    
    if not mag_in_hold.empty:
        picco_idx = mag_in_hold.idxmax()
        df['label'] = 0
        inizio = max(0, picco_idx - 30)
        fine = min(len(df), picco_idx + 60)
        df.loc[inizio:fine, 'label'] = 1
# ================================================================

print("\n2. Preparazione dei frame di test (Sliding Window 3s)...")
window_size = 90
step_size = 15
features_list = []
true_labels = []

for i in range(0, len(df) - window_size, step_size):
    window = df.iloc[i : i + window_size]
    
    # Salva la label vera per il confronto finale (Apple non la vedrà)
    vera_label = 1 if (window['label'] == 1).any() else 0
    true_labels.append(vera_label)
    
    acc_mag = np.sqrt(window['acc_x']**2 + window['acc_y']**2 + window['acc_z']**2)
    gyro_mag = np.sqrt(window['gyro_x']**2 + window['gyro_y']**2 + window['gyro_z']**2)
    
    # CoreML esige float() nativi di Python, non numpy.float64
    feats = {
        'acc_z_min': float(window['acc_z'].min()),
        'acc_z_max': float(window['acc_z'].max()),
        'acc_z_var': float(window['acc_z'].var()),
        'mag_mean': float(acc_mag.mean()),
        'mag_max': float(acc_mag.max()),
        'gyro_mag_max': float(gyro_mag.max())
    }
    features_list.append(feats)

print("\n3. Interrogazione del modello Apple...")
try:
    model = ct.models.MLModel("FallDetector.mlpackage")
except Exception as e:
    print("❌ Errore: FallDetector.mlpackage non trovato. Hai lanciato train.py prima?")
    exit()

predictions = []
for feat in features_list:
    risultato = model.predict(feat)
    predictions.append(risultato['classLabel'])

print("\n========== 📊 REPORT PRESTAZIONI FINALI ==========\n")

cm = confusion_matrix(true_labels, predictions)
print("📌 MATRICE DI CONFUSIONE:")
if cm.size == 4:
    print(f"Veri Negativi (Normale, ignorato):  {cm[0][0]}")
    print(f"Falsi Positivi (Falso Allarme!):    {cm[0][1]}")
    print(f"Falsi Negativi (Caduta Mancata!):   {cm[1][0]}")
    print(f"Veri Positivi (Caduta Rilevata):    {cm[1][1]}")
else:
    print(cm)
    print("(Il file di test conteneva solo una classe, aggiungi sia cadute che movimenti normali per la matrice completa)")

print("\n📌 METRICHE DETTAGLIATE:")
try:
    print(classification_report(true_labels, predictions, target_names=['Normale (0)', 'Caduta (1)']))
except ValueError:
    print("Report limitato perché nel file test_reali.csv manca una delle due classi.")
