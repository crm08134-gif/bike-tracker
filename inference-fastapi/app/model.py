"""
모델 구성 · 가중치 로드 · 추론 (계획서 3절 7~9단계).

원본 대응:
  DeepInsightDataset / Normalize   L655
  timm resnet18 + stem 수정 + fc   L696~L705
  le.classes_ 라벨 복원 [FIX-5]    L629
"""
from __future__ import annotations

import hashlib
import pickle
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import timm
import torch
import torch.nn as nn

from . import pipeline


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class Artifacts:
    """pkl 에서 읽은 전처리 아티팩트 일체."""

    feature_columns: list[str]
    pixel_to_feats: dict
    qt: object
    le_classes: list[str]
    img_size: int
    window_size: int
    stride: int
    accuracy_limit: int
    stop_threshold: float
    tsfel_fs: float
    seg_gap_sec: int
    normalize_mean: list[float]
    normalize_std: list[float]
    versions: dict
    results: dict
    pkl_sha256: str

    @classmethod
    def load(cls, pkl_path: Path) -> "Artifacts":
        with pkl_path.open("rb") as f:
            d = pickle.load(f)
        return cls(
            feature_columns=list(d["FEATURE_COLUMNS"]),
            pixel_to_feats=d["pixel_to_feats"],
            qt=d["qt"],
            le_classes=list(d["le_classes"]),
            img_size=int(d["IMG_SIZE"]),
            window_size=int(d["WINDOW_SIZE"]),
            stride=int(d["STRIDE"]),
            accuracy_limit=int(d["ACC_FILTER_M"]),
            stop_threshold=float(d["STOP_THRESHOLD"]),
            tsfel_fs=float(d["TSFEL_FS"]),
            seg_gap_sec=int(d["SEG_GAP_SEC"]),
            normalize_mean=list(d["NORMALIZE"]["mean"]),
            normalize_std=list(d["NORMALIZE"]["std"]),
            versions=dict(d["versions"]),
            results=dict(d.get("results", {})),
            pkl_sha256=_sha256(pkl_path),
        )


def build_model(n_classes: int) -> nn.Module:
    """
    원본 L696~L705 와 동일한 구조.

    서빙은 pretrained=False 다. True 면 기동할 때마다 ImageNet 가중치를
    내려받으려 하고, 어차피 바로 뒤에서 우리 가중치로 덮어쓴다.
    """
    model = timm.create_model("resnet18", pretrained=False, num_classes=n_classes)
    model.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
    model.maxpool = nn.Identity()
    fc_in = model.fc.in_features
    model.fc = nn.Sequential(nn.Dropout(p=0.3), nn.Linear(fc_in, n_classes))
    return model


class Predictor:
    """기동 시 한 번만 만들고 이후 재사용한다."""

    def __init__(self, art: Artifacts, pth_path: Path, device: str = "cpu"):
        self.art = art
        self.device = torch.device(device)
        self.pth_sha256 = _sha256(pth_path)

        self.model = build_model(len(art.le_classes))
        state = torch.load(pth_path, map_location="cpu", weights_only=True)
        # 학습 저장 방식에 따라 래핑되어 있을 수 있다
        for key in ("state_dict", "model_state_dict"):
            if isinstance(state, dict) and key in state:
                state = state[key]
                break
        missing, unexpected = self.model.load_state_dict(state, strict=True)
        self.model.eval().to(self.device)

        self._mean = torch.tensor(art.normalize_mean).view(3, 1, 1)
        self._std = torch.tensor(art.normalize_std).view(3, 1, 1)

        self.model_version = (
            f"korea_ft_fixed+pth:{self.pth_sha256[:12]}+pkl:{art.pkl_sha256[:12]}"
        )

    # ── 7단계: 텐서 변환 (원본 L655 DeepInsightDataset + transform) ─────────
    def _to_tensor(self, imgs: np.ndarray) -> torch.Tensor:
        x = torch.from_numpy(imgs).unsqueeze(1).repeat(1, 3, 1, 1)
        x = (x - self._mean) / self._std
        return x.to(self.device)

    # ── 8~9단계: 모델 실행 → softmax → 라벨 ────────────────────────────────
    @torch.inference_mode()
    def predict_images(self, imgs: np.ndarray):
        x = self._to_tensor(imgs)
        logits = self.model(x)
        probs = torch.softmax(logits, dim=1).cpu().numpy()
        idx = probs.argmax(axis=1)
        # [FIX-5] 인덱스를 코드에 적지 않는다. 항상 pkl 의 le_classes 에서 읽는다.
        labels = [self.art.le_classes[i] for i in idx]
        return labels, probs

    def predict_windows(self, windows: list[list[dict]]):
        art = self.art
        X, imgs = pipeline.windows_to_images(
            windows,
            feature_columns=art.feature_columns,
            qt=art.qt,
            pixel_to_feats=art.pixel_to_feats,
            img_size=art.img_size,
            window_size=art.window_size,
        )
        labels, probs = self.predict_images(imgs)
        return labels, probs, X, imgs

    def probs_to_dict(self, row: np.ndarray) -> dict[str, float]:
        """5개 클래스가 모두 들어간 dict. Spring 이 평균낼 때 필요하다."""
        return {c: float(row[i]) for i, c in enumerate(self.art.le_classes)}
