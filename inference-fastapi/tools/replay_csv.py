"""
폰 CSV 주행을 Spring 규칙대로 잘라 추론까지 재생한다 (계획서 6절 '실제 앱 데이터').

    python tools/replay_csv.py trip.csv
    python tools/replay_csv.py trip.csv --strategy STRICT_BIKE

CSV 컬럼: session_id, ts, lat, lng, acc, spd, alt, label

Spring 이 하는 일을 그대로 따라한다:
  정확도 20m 초과 제거 → ts 비증가 제거 → 300초 공백으로 구간 분리
  → 200점/stride 100 절단 (200 미만 꼬리는 버림) → 추론 → 겹침 규칙
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.model import Artifacts, Predictor  # noqa: E402
from app.pipeline import haversine  # noqa: E402


def build_windows(df: pd.DataFrame, art) -> tuple[list, list]:
    """Spring 의 절단 규칙 재현."""
    df = df.sort_values("ts").reset_index(drop=True)
    n0 = len(df)

    if "acc" in df.columns:
        df = df[df["acc"] <= art.accuracy_limit].reset_index(drop=True)
    n_acc = n0 - len(df)

    df = df[df["ts"].diff().fillna(1) > 0].reset_index(drop=True)
    n_ts = n0 - n_acc - len(df)

    gap = df["ts"].diff().fillna(0) / 1000.0
    df["_seg"] = (gap > art.seg_gap_sec).cumsum()

    windows, meta = [], []
    for seg_id, g in df.groupby("_seg"):
        g = g.reset_index(drop=True)
        for start in range(0, len(g), art.stride):
            w = g.iloc[start : start + art.window_size]
            if len(w) < art.window_size:
                break
            windows.append(
                [
                    {"ts": int(r.ts), "lat": float(r.lat), "lng": float(r.lng)}
                    for r in w.itertuples()
                ]
            )
            meta.append(
                {
                    "seg": int(seg_id),
                    "start": start,
                    "t0": int(w.ts.iloc[0]),
                    "t1": int(w.ts.iloc[-1]),
                    "n_global": len(windows) - 1,
                }
            )

    print(f"원본 {n0}행 → 정확도 필터 -{n_acc} → ts 필터 -{n_ts} → {len(df)}행")
    print(f"구간 {df['_seg'].nunique()}개, 200점 묶음 {len(windows)}개")
    return windows, meta


def overlap_resolve(probs, meta, classes, strategy: str, n_points: int):
    """
    Spring 의 tracker.overlap-strategy 세 방식을 점 단위로 재현한다.
    반환: 점별 라벨 배열
    """
    bike_i = classes.index("bike")
    out = np.empty(n_points, dtype=object)
    out[:] = None

    if strategy == "AVERAGE_PROBS":
        acc = np.zeros((n_points, len(classes)))
        cnt = np.zeros(n_points)
        for k, m in enumerate(meta):
            s = m["start"]
            acc[s : s + 200] += probs[k]
            cnt[s : s + 200] += 1
        covered = cnt > 0
        avg = np.zeros_like(acc)
        avg[covered] = acc[covered] / cnt[covered, None]
        idx = avg.argmax(1)
        out[covered] = [classes[i] for i in idx[covered]]

    elif strategy == "LATEST_WINDOW":
        for k, m in enumerate(meta):
            s = m["start"]
            out[s : s + 200] = classes[int(probs[k].argmax())]

    elif strategy == "STRICT_BIKE":
        votes: dict[int, list[bool]] = {}
        for k, m in enumerate(meta):
            s = m["start"]
            is_bike = int(probs[k].argmax()) == bike_i
            for i in range(s, s + 200):
                votes.setdefault(i, []).append(is_bike)
        for i, v in votes.items():
            out[i] = "bike" if all(v) else "not-bike"
    else:
        raise SystemExit(f"알 수 없는 전략: {strategy}")
    return out


def report_breaks(labels) -> None:
    """bike 구간이 몇 번 끊기는지."""
    seq = [x for x in labels if x is not None]
    runs = []
    for x in seq:
        if runs and runs[-1][0] == x:
            runs[-1][1] += 1
        else:
            runs.append([x, 1])

    print("\n점별 판정:", dict(Counter(seq)))
    bike_runs = [r for r in runs if r[0] == "bike"]
    print(f"연속 구간 {len(runs)}개 (bike 구간 {len(bike_runs)}개)")
    if len(bike_runs) > 1:
        print(f"  → bike 궤적이 {len(bike_runs) - 1}번 끊깁니다")
    print("\n  구간 나열:")
    for lab, n in runs:
        print(f"    {lab:<9} {n:>4}점 ({n}초)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument(
        "--strategy",
        default="AVERAGE_PROBS",
        choices=["AVERAGE_PROBS", "STRICT_BIKE", "LATEST_WINDOW"],
    )
    ap.add_argument("--models", default=str(ROOT / "models"))
    args = ap.parse_args()

    md = Path(args.models)
    art = Artifacts.load(md / "inference_artifacts.pkl")
    pred = Predictor(art, md / "resnet18_korea_ft_fixed.pth")

    df = pd.read_csv(args.csv)
    lat, lng = df.lat.values, df.lng.values
    total = haversine(lat[:-1], lng[:-1], lat[1:], lng[1:]).sum()
    mins = (df.ts.iloc[-1] - df.ts.iloc[0]) / 1000 / 60
    print(f"=== {Path(args.csv).name} ===")
    print(f"{len(df)}행 {mins:.1f}분 이동 {total:.0f}m 평균 {total / (mins * 60) * 3.6:.1f} km/h")
    if "label" in df.columns:
        print("정답 라벨:", df.label.value_counts().to_dict())
    print()

    windows, meta = build_windows(df, art)
    if not windows:
        raise SystemExit("200점 묶음이 하나도 안 나옵니다. 주행이 너무 짧습니다.")

    labels, probs, _, _ = pred.predict_windows(windows)

    print("\n--- 묶음별 판정 ---")
    for k, (m, lab) in enumerate(zip(meta, labels)):
        t0 = pd.to_datetime(m["t0"], unit="ms", utc=True).tz_convert("Asia/Seoul")
        t1 = pd.to_datetime(m["t1"], unit="ms", utc=True).tz_convert("Asia/Seoul")
        dist = " ".join(f"{c}={v:.2f}" for c, v in zip(art.le_classes, probs[k]))
        print(f"  W{k} seg{m['seg']} {t0:%H:%M:%S}~{t1:%H:%M:%S} → {lab:<7} {dist}")

    n_points = max(m["start"] for m in meta) + art.window_size
    print(f"\n--- 겹침 규칙: {args.strategy} ---")
    report_breaks(overlap_resolve(probs, meta, art.le_classes, args.strategy, n_points))


if __name__ == "__main__":
    main()
