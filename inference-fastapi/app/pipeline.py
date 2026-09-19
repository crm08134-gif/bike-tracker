"""
추론 전처리 파이프라인 (계획서 3절 1~7단계).

이 파일의 함수 본문은 zeroshot_korea_test_fixed.py 에서 **그대로 복사**한 것입니다.
수정하지 마세요. 학습과 서버의 계산이 한 줄이라도 달라지면 정확도가 조용히 떨어집니다.

원본 대응:
  haversine                    L109
  bearing                      L124
  top3_mean                    L138
  drop_nonincreasing_time      L150   → 서버에서는 검증용으로만 사용
  compute_point_features       L253
  extract_statistical_features L315
  extract_tsfel_features       L356
  reindex / nan_to_num         L859 / L940
  _make_images                 L552
"""
from __future__ import annotations

import numpy as np
import pandas as pd
import tsfel

# ── 학습 코드 L75~L85 의 상수. 실제 값은 pkl 에서 읽어 주입한다 ──────────────
STOP_THRESHOLD = 0.5
MOTION_FEATURES = [
    "speed_ms",
    "acceleration_ms2",
    "jerk_ms3",
    "bearing_deg",
    "bearing_rate_degs",
]


# ── 지리 계산 유틸리티 (원본 L109~L146) ──────────────────────────────────────
def haversine(lat1, lon1, lat2, lon2):
    R = 6_371_000
    phi1 = np.radians(lat1)
    phi2 = np.radians(lat2)
    dphi = np.radians(lat2 - lat1)
    dlambda = np.radians(lon2 - lon1)
    a = np.sin(dphi / 2) ** 2 + np.cos(phi1) * np.cos(phi2) * np.sin(dlambda / 2) ** 2
    return R * 2 * np.arctan2(np.sqrt(a), np.sqrt(1 - a))


def bearing(lat1, lon1, lat2, lon2):
    lat1 = np.radians(lat1)
    lat2 = np.radians(lat2)
    dlon = np.radians(lon2 - lon1)
    x = np.sin(dlon) * np.cos(lat2)
    y = np.cos(lat1) * np.sin(lat2) - np.sin(lat1) * np.cos(lat2) * np.cos(dlon)
    return (np.degrees(np.arctan2(x, y)) + 360) % 360


def top3_mean(series):
    vals = series.dropna().values
    return np.nan if len(vals) == 0 else np.mean(np.sort(vals)[-3:])


# ── 1단계: 입력 검증 (원본 drop_nonincreasing_time L150 과 같은 규칙) ────────
class WindowSizeError(ValueError):
    """points 가 WINDOW_SIZE 개가 아님 → 422 WINDOW_SIZE"""


class NonIncreasingTsError(ValueError):
    """ts 가 같거나 거꾸로 감 → 422 NON_INCREASING_TS"""


def validate_window(points: list[dict], window_size: int) -> None:
    """
    Spring 이 보장하기로 한 두 조건을 서버에서 한 번 더 확인한다.

    학습 쪽은 drop_nonincreasing_time 으로 '제거'했지만, 서버는 제거하면
    200개가 깨지므로 '거부'한다. 여기서 걸린다는 것은 Spring 의 절단 로직이
    깨졌다는 뜻이므로 retryable=false 로 돌려보낸다.
    """
    if len(points) != window_size:
        raise WindowSizeError(f"points 가 {window_size}개가 아닙니다 (받은 개수: {len(points)})")

    ts = np.asarray([p["ts"] for p in points], dtype=np.int64)
    bad = np.nonzero(np.diff(ts) <= 0)[0]
    if bad.size:
        i = int(bad[0])
        raise NonIncreasingTsError(
            f"ts 가 증가하지 않습니다 (index {i}: {ts[i]} → {ts[i + 1]})"
        )


def points_to_raw_df(points: list[dict]) -> pd.DataFrame:
    """
    요청 JSON → 학습 코드가 기대하는 (time, latitude, longitude) DataFrame.

    학습 L900 이 pd.to_datetime(timestamp_ms, unit='ms') 로 tz 없는 datetime 을
    만들었으므로 여기서도 똑같이 한다. 이후 계산은 시각의 '차이'만 쓰므로
    시간대가 무엇이든 결과가 같다.
    """
    return pd.DataFrame(
        {
            "time": pd.to_datetime([p["ts"] for p in points], unit="ms"),
            "latitude": np.asarray([p["lat"] for p in points], dtype=np.float64),
            "longitude": np.asarray([p["lng"] for p in points], dtype=np.float64),
        }
    )


# ── 2단계: 점별 운동 신호 (원본 L253) ────────────────────────────────────────
def compute_point_features(raw_df):
    df = raw_df.copy()
    lat = df["latitude"].values
    lon = df["longitude"].values

    dist = np.full(len(df), np.nan)
    tdiff = np.full(len(df), np.nan)
    bear = np.full(len(df), np.nan)

    dist[1:] = haversine(lat[:-1], lon[:-1], lat[1:], lon[1:])
    tdiff[1:] = df["time"].diff().dt.total_seconds().values[1:]
    bear[1:] = bearing(lat[:-1], lon[:-1], lat[1:], lon[1:])

    # [FIX-1] 0/음수 시간차를 NaN 으로 강등 (inf 방지)
    tdiff = np.where((tdiff <= 0) | ~np.isfinite(tdiff), np.nan, tdiff)

    df["distance_m"] = dist
    df["time_diff_s"] = tdiff
    df["bearing_deg"] = bear

    df["speed_ms"] = df["distance_m"] / df["time_diff_s"]
    df["acceleration_ms2"] = df["speed_ms"].diff() / df["time_diff_s"]
    df["jerk_ms3"] = df["acceleration_ms2"].diff() / df["time_diff_s"]
    df["bearing_rate_degs"] = df["bearing_deg"].diff() / df["time_diff_s"]

    # [FIX-1] inf 도 함께 제거
    point_cols = [
        "distance_m",
        "time_diff_s",
        "speed_ms",
        "acceleration_ms2",
        "jerk_ms3",
        "bearing_deg",
        "bearing_rate_degs",
    ]
    df[point_cols] = df[point_cols].replace([np.inf, -np.inf], np.nan).fillna(0)
    return df


# ── 3단계: 통계 피처 43개 (원본 L315) ────────────────────────────────────────
def extract_statistical_features(df):
    feat = {}
    for f in MOTION_FEATURES:
        s = df[f]
        feat[f"{f}_min"] = s.min()
        feat[f"{f}_mean"] = s.mean()
        feat[f"{f}_median"] = s.median()
        feat[f"{f}_std"] = s.std()
        feat[f"{f}_p25"] = s.quantile(0.25)
        feat[f"{f}_p75"] = s.quantile(0.75)
        feat[f"{f}_p95"] = s.quantile(0.95)
        feat[f"{f}_top3"] = top3_mean(s)

    feat["stop_ratio"] = (df["speed_ms"] < STOP_THRESHOLD).sum() / len(df)
    feat["straight_dist_m"] = haversine(
        df["latitude"].iloc[0],
        df["longitude"].iloc[0],
        df["latitude"].iloc[-1],
        df["longitude"].iloc[-1],
    )
    feat["total_dist_m"] = df["distance_m"].sum()
    return pd.Series(feat)


# ── 4단계: TSFEL 피처 (원본 L356) ────────────────────────────────────────────
# 설정 사전은 전역에서 한 번만 만든다 (원본과 동일).
_tsfel_cfg = {
    domain: tsfel.get_features_by_domain(domain)
    for domain in ["statistical", "temporal", "spectral"]
}


def extract_tsfel_features(df):
    """
    원본 L356 과 동일. except Exception: continue 도 그대로 둔다.

    [중요] 학습 환경에서는 spectral 도메인이 매번 예외를 냈고 그 결과
    FEATURE_COLUMNS 178개에 spectral 컬럼이 하나도 없다(statistical 93 +
    temporal 42 + 통계 43). 이 try/except 를 '고치면' 학습 때 없던 컬럼이
    생기는데, 5단계 reindex 가 여분 컬럼을 버리므로 결과는 같지만 쓸데없이
    느려진다. 건드리지 말 것.
    """
    tsfel_signal_cols = ["speed_ms", "acceleration_ms2", "jerk_ms3"]
    parts = []
    for col in tsfel_signal_cols:
        values = df[col].to_numpy(dtype=np.float64, na_value=0.0)
        single_sig = pd.DataFrame({"signal": values})
        col_feats = {}

        for domain, cfg in _tsfel_cfg.items():
            try:
                feats = tsfel.time_series_features_extractor(
                    cfg, single_sig, fs=1.0, verbose=0
                )
                feats = feats.loc[:, ~feats.columns.duplicated()]
                for feat_col in feats.columns:
                    col_feats[f"{col}__{domain}__{feat_col}"] = feats[feat_col].iloc[0]
            except Exception:
                continue

        if col_feats:
            parts.append(pd.Series(col_feats))

    if not parts:
        return pd.Series(dtype=float)

    result = pd.concat(parts)
    return result[~result.index.duplicated(keep="first")]


# ── 3+4 를 합쳐 하나의 피처 벡터로 (원본 L828~L836 의 윈도우 처리부) ────────
def extract_feature_series(fdf) -> pd.Series:
    fv = pd.concat([extract_statistical_features(fdf), extract_tsfel_features(fdf)])
    fv.index = fv.index.astype(str)
    return fv


# ── 5단계: 컬럼 순서 고정 (원본 L859 reindex + L940 nan_to_num) ─────────────
def align_features(fv_list: list[pd.Series], feature_columns: list[str]) -> np.ndarray:
    """
    FEATURE_COLUMNS 순서로 재정렬한다. 순서가 바뀌면 픽셀 위치가 바뀌어
    정확도가 무너지므로 이름 기준 reindex 만 사용한다.
    """
    feat_df = pd.DataFrame(fv_list)
    feat_df = feat_df.reindex(columns=feature_columns, fill_value=0).fillna(0)
    X = feat_df.values.astype(np.float32)
    return np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)


# ── 6단계: DeepInsight 이미지 (원본 _make_images L552) ──────────────────────
def make_images(X_input, qt, pixel_to_feats, img_size: int):
    X_norm = np.clip(qt.transform(X_input), 0.0, 1.0)
    imgs = np.zeros((len(X_input), img_size, img_size), dtype=np.float32)
    for (r, c), fidxs in pixel_to_feats.items():
        imgs[:, r, c] = X_norm[:, fidxs].mean(axis=1)
    return imgs


# ── 1~6단계 묶음 실행 ────────────────────────────────────────────────────────
def windows_to_images(
    windows: list[list[dict]],
    *,
    feature_columns,
    qt,
    pixel_to_feats,
    img_size: int,
    window_size: int,
):
    """
    요청 묶음 여러 개 → (features, images).
    features 는 parity 테스트에서 비교하므로 함께 돌려준다.
    """
    fv_list = []
    for points in windows:
        validate_window(points, window_size)
        raw = points_to_raw_df(points)
        fdf = compute_point_features(raw)
        fv_list.append(extract_feature_series(fdf))

    X = align_features(fv_list, feature_columns)
    imgs = make_images(X, qt, pixel_to_feats, img_size)
    return X, imgs
