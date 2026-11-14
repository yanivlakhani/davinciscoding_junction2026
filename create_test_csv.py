import pandas as pd
import numpy as np

print("Generazione del file test_reali.csv...")

# Creiamo 300 frame (10 secondi a 30 FPS) di movimenti normali
righe = 300
df = pd.DataFrame({
    'acc_x': np.random.normal(0, 1, righe),
    'acc_y': np.random.normal(0, 1, righe),
    'acc_z': np.random.normal(-9.8, 1, righe), # Gravità terrestre standard
    'gyro_x': np.random.normal(0, 0.5, righe),
    'gyro_y': np.random.normal(0, 0.5, righe),
    'gyro_z': np.random.normal(0, 0.5, righe),
    'label': 0
})

# Simuliamo che il tuo compagno tenga premuto HOLD dal frame 100 al 180
df.loc[100:180, 'label'] = 1

# Simuliamo il picco di impatto esatto al frame 150
df.loc[150, 'acc_z'] = -25.0
df.loc[150, 'acc_x'] = 15.0
df.loc[151, 'acc_z'] = -18.0
df.loc[151, 'gyro_z'] = 8.0 # Torsione improvvisa

# Salvataggio
df.to_csv("test_reali.csv", index=False)
print("✅ Fatto! 'test_reali.csv' creato nella cartella.")
