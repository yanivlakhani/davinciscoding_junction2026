import pandas as pd
import numpy as np
import glob
import os
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report
import coremltools as ct

csv_files = glob.glob("dati_raccolti/**/*.csv", recursive=True)

if not csv_files:
    print("❌ Errore: Nessun CSV trovato in 'dati_raccolti'.")
    exit()

window_size = 90
step_size = 15
features_list = []

print(f"Trovati {len(csv_files)} file CSV. Inizio elaborazione...")

for file in csv_files:
    df = pd.read_csv(file)
    
    # Controlliamo il nuovo nome della colonna
    if 'falling' not in df.columns:
        continue

    # 🔥 AUTO-TRIMMER con il nuovo nome 'falling' 🔥
    if (df['falling'] == 1).any():
        # Usa accelerometer_x, y, z
        acc_mag = np.sqrt(df['accelerometer_x']**2 + df['accelerometer_y']**2 + df['accelerometer_z']**2)
        mag_in_hold = acc_mag[df['falling'] == 1]
        
        if not mag_in_hold.empty:
            picco_idx = mag_in_hold.idxmax()
            df['falling'] = 0
            inizio = max(0, picco_idx - 30)
            fine = min(len(df), picco_idx + 60)
            df.loc[inizio:fine, 'falling'] = 1

    # ESTRAZIONE FEATURE
    for i in range(0, len(df) - window_size, step_size):
        window = df.iloc[i : i + window_size]
        is_fall = 1 if (window['falling'] == 1).any() else 0
        
        acc_mag = np.sqrt(window['accelerometer_x']**2 + window['accelerometer_y']**2 + window['accelerometer_z']**2)
        gyro_mag = np.sqrt(window['gyroscope_x']**2 + window['gyroscope_y']**2 + window['gyroscope_z']**2)
        
        # Manteniamo i nomi delle chiavi invariati per non rompere il codice Swift iOS
        feats = {
            'acc_z_min': window['accelerometer_z'].min(),
            'acc_z_max': window['accelerometer_z'].max(),
            'acc_z_var': window['accelerometer_z'].var(),
            'mag_mean': acc_mag.mean(),
            'mag_max': acc_mag.max(),
            'gyro_mag_max': gyro_mag.max(),
            'orient_x_mean': window['orientation_x'].mean(), 
            'orient_y_mean': window['orientation_y'].mean(), 
            'orient_z_mean': window['orientation_z'].mean(), 
            'label_finale': is_fall
        }
        features_list.append(feats)

dataset = pd.DataFrame(features_list)
print(f"✅ Generate {len(dataset)} finestre di dati da 3 secondi.")

X = dataset.drop('label_finale', axis=1)
y = dataset['label_finale']

X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
clf = RandomForestClassifier(n_estimators=30, max_depth=6, random_state=42)
clf.fit(X_train, y_train)

y_pred = clf.predict(X_test)
print("\n========== REPORT PRESTAZIONI ==========")
print(classification_report(y_test, y_pred))

feature_names = list(X.columns)
coreml_model = ct.converters.sklearn.convert(clf, input_features=feature_names)
coreml_model.short_description = "Detector Cadute per Meta Glasses"
coreml_model.save("FallDetector.mlpackage")
print("✅ FallDetector.mlpackage salvato.")
