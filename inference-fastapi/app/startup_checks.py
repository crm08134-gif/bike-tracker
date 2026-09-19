"""
기동 검사 (계획서 4절). 하나라도 실패하면 기동을 거부한다.

  1) 설치 버전과 pkl 의 versions 비교
  2) sklearn · tsfel 이 다르면 기동 거부 (나머지는 경고만)
  3) 더미 묶음으로 피처를 한 번 뽑아 FEATURE_COLUMNS 와 대조
  4) model_version 을 두 파일 해시로 구성 (Predictor 가 담당)

3번이 특히 중요하다. 5단계 reindex 가 빠진 컬럼을 0 으로 채우기 때문에,
이 검사가 없으면 컬럼이 사라져도 오류 없이 정확도만 조용히 떨어진다.
"""
from __future__ import annotations

import importlib.metadata as md
import math

import numpy as np

from . import pipeline

# pkl 의 versions 키 → 설치된 배포판 이름
_DIST = {
    "sklearn": "scikit-learn",
    "torch": "torch",
    "timm": "timm",
    "tsfel": "tsfel",
    "numpy": "numpy",
    "pandas": "pandas",
}

# 이 둘이 어긋나면 결과가 조용히 틀어지므로 기동을 거부한다.
#   sklearn : pkl 안의 qt(QuantileTransformer)를 읽는 주체
#   tsfel   : 피처 목록 자체가 바뀜
FATAL = ("sklearn", "tsfel")


class StartupCheckError(RuntimeError):
    pass


def _installed(name: str) -> str | None:
    try:
        return md.version(_DIST[name])
    except Exception:
        return None


def _base(v: str | None) -> str | None:
    """'2.11.0+cu128' 과 '2.11.0+cpu' 를 같은 것으로 본다."""
    return v.split("+")[0] if v else v


def check_versions(expected: dict) -> list[str]:
    warnings: list[str] = []
    fatal: list[str] = []

    for name, want in expected.items():
        if name not in _DIST or want is None:
            continue
        got = _installed(name)
        if got is None:
            fatal.append(f"{name}: 설치되지 않음 (기대 {want})")
            continue
        if name in FATAL:
            if got != want:
                fatal.append(f"{name}: 설치 {got} ≠ pkl {want}")
        elif _base(got) != _base(want):
            warnings.append(f"{name}: 설치 {got} ≠ pkl {want}")

    if fatal:
        raise StartupCheckError(
            "버전 불일치로 기동을 거부합니다:\n  - " + "\n  - ".join(fatal)
        )
    return warnings


def _dummy_points(window_size: int) -> list[dict]:
    """
    직선 위를 대략 시속 18km 로 달리는 가짜 주행. 1초 간격, ts 엄격 증가.
    값이 무엇이든 상관없다. 중요한 건 '어떤 컬럼이 나오는가' 뿐이다.
    """
    base_ts = 1_700_000_000_000
    lat, lng = 37.5, 127.0
    pts = []
    for i in range(window_size):
        # 약간의 곡률을 줘서 bearing_rate 가 0 으로만 채워지지 않게 한다
        lat += 4.5e-5 * math.cos(i / 17.0)
        lng += 4.5e-5 * math.sin(i / 23.0)
        pts.append({"ts": base_ts + i * 1000, "lat": lat, "lng": lng})
    return pts


def check_feature_columns(feature_columns: list[str], window_size: int) -> dict:
    """
    더미 묶음으로 피처를 한 번 뽑아 FEATURE_COLUMNS 와 대조한다.
    빠진 컬럼이 하나라도 있으면 기동 실패.
    """
    raw = pipeline.points_to_raw_df(_dummy_points(window_size))
    fdf = pipeline.compute_point_features(raw)
    produced = set(pipeline.extract_feature_series(fdf).index)

    expected = set(feature_columns)
    missing = sorted(expected - produced)
    extra = sorted(produced - expected)

    if missing:
        head = ", ".join(missing[:10])
        raise StartupCheckError(
            f"피처 컬럼 {len(missing)}개가 생성되지 않았습니다. "
            f"tsfel/scipy 버전을 확인하세요.\n  누락: {head}"
            + (" ..." if len(missing) > 10 else "")
        )
    # extra 는 5단계 reindex 가 버리므로 치명적이지 않다. 기록만 남긴다.
    return {"missing": missing, "extra": extra}


def run_all(art) -> dict:
    version_warnings = check_versions(art.versions)
    col_report = check_feature_columns(art.feature_columns, art.window_size)
    return {
        "version_warnings": version_warnings,
        "feature_columns_check": col_report,
    }
