import pandas as pd
import numpy as np

print("Generazione del CSV fake in corso...")

righe = 1000 # Simula 20 secondi di dati a 50Hz
df = pd.DataFrame({
    'acc_x': np.random.normal(0, 1, righe),
    'acc_y': np.random.normal(0, 1, righe),
    'acc_z': np.random.normal(-9.8, 3, righe), # Simula la gravità sull'asse verticale
    'gyro_x': np.random.normal(0, 0.5, righe),
    'gyro_y': np.random.normal(0, 0.5, righe),
    'gyro_z': np.random.normal(0, 0.5, righe),
    'label': np.random.choice([0, 1], righe)   # Alterna a caso movimenti normali (0) e cadute (1)
})

# Salva il file nella stessa cartella
df.to_csv("cadute_reali.csv", index=False)
print("✅ File 'cadute_reali.csv' generato con successo!")
