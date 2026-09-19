"""학습-서버 일치 검증 (계획서 6절)."""
import json, time, sys
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.model import Artifacts, Predictor

art = Artifacts.load(ROOT / "models" / "inference_artifacts.pkl")
pred = Predictor(art, ROOT / "models" / "resnet18_korea_ft_fixed.pth")

reqs = json.loads((ROOT / "golden" / "golden_requests.json").read_text())
z = np.load(ROOT / "golden" / "golden_intermediate.npz", allow_pickle=True)

print("model_version:", pred.model_version)
print("manifest     :", json.loads((ROOT/"golden"/"manifest.json").read_text())["model_version"])

windows = [r["request"]["points"] for r in reqs]
t0 = time.perf_counter()
labels, probs, X, imgs = pred.predict_windows(windows)
el = time.perf_counter() - t0
print(f"\n{len(windows)}개 처리 {el:.2f}s  → 묶음당 {el/len(windows)*1000:.0f} ms")

gX, gI, gP, gL = z["features"], z["images"], z["probs"], z["pred_names"]
print("\n--- 중간 산출물 최대 오차 ---")
print(f"features : {np.abs(X - gX).max():.3e}")
print(f"images   : {np.abs(imgs - gI).max():.3e}")
print(f"probs    : {np.abs(probs - gP).max():.3e}")
match = sum(a == b for a, b in zip(labels, gL))
print(f"\n라벨 일치 : {match}/{len(gL)}")
for i, r in enumerate(reqs):
    flag = "OK " if labels[i] == gL[i] else "MISMATCH "
    print(f"  {flag}{r['golden_id']:>9} golden={gL[i]:<7} server={labels[i]:<7} true={r['true_mode']}")
assert match == len(gL), "라벨 불일치 — 파이프라인이 어긋났습니다"
print("\nPARITY PASS")
