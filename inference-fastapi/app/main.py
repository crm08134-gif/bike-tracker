"""
FastAPI 추론 서버. 계약은 인수인계 문서 2절을 그대로 따른다.

  POST /v1/predict         200점 한 묶음
  POST /v1/predict/batch   여러 묶음. 요청과 같은 길이·같은 순서로 응답
  GET  /v1/model           모델 메타데이터
  GET  /healthz            로드 전 503, 후 200

모델은 기동 때 한 번만 로드한다(M3 완료 기준).
"""
from __future__ import annotations

import logging
import os
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

import importlib.metadata as md
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .model import Artifacts, Predictor
from .pipeline import NonIncreasingTsError, WindowSizeError
from .startup_checks import StartupCheckError, run_all

log = logging.getLogger("inference")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

MODEL_DIR = Path(os.getenv("MODEL_DIR", "/app/models"))
PKL_PATH = MODEL_DIR / os.getenv("PKL_NAME", "inference_artifacts.pkl")
PTH_PATH = MODEL_DIR / os.getenv("PTH_NAME", "resnet18_korea_ft_fixed.pth")

# 파이토치가 컨테이너 CPU 를 전부 잡고 스레드 경합을 일으키지 않도록 제한
TORCH_THREADS = int(os.getenv("TORCH_NUM_THREADS", "2"))

# 한 번에 추론을 몇 개까지 동시에 돌릴지. uvicorn 은 동기 핸들러를 스레드풀
# (기본 40개)에서 실행하므로, 제한이 없으면 세션이 여러 개일 때 torch 스레드가
# CPU 를 두고 서로 경합해 지연 시간이 예측 불가능해진다. 요청이 세션당 100초에
# 한 번뿐이라 직렬로 처리해도 충분하다.
INFER_CONCURRENCY = int(os.getenv("INFER_CONCURRENCY", "1"))
_infer_lock = threading.Semaphore(INFER_CONCURRENCY)

# read timeout 30초 대비 안전선. 묶음당 약 60ms 이므로 256개면 약 15초.
# 넘겨도 거부하지 않는다 (거부하면 Spring 이 그 묶음을 통째로 잃는다).
# 경고만 남기고, Spring 이 쪼갤 수 있도록 GET /v1/model 에 값을 실어 보낸다.
MAX_BATCH_SIZE = int(os.getenv("MAX_BATCH_SIZE", "256"))


class _State:
    """로드 상태. predictor 가 None 이면 아직 준비되지 않은 것이다."""

    predictor: Predictor | None = None
    report: dict | None = None
    error: str | None = None


state = _State()


def _load() -> None:
    try:
        import torch

        torch.set_num_threads(TORCH_THREADS)

        t0 = time.perf_counter()
        art = Artifacts.load(PKL_PATH)
        report = run_all(art)
        for w in report["version_warnings"]:
            log.warning("버전 경고 %s", w)
        if report["feature_columns_check"]["extra"]:
            log.info(
                "학습에 없던 컬럼 %d개는 무시됩니다",
                len(report["feature_columns_check"]["extra"]),
            )

        predictor = Predictor(art, PTH_PATH, device="cpu")

        # 예열. 첫 요청은 torch·tsfel 내부 초기화 때문에 평소의 10배 넘게
        # 걸린다(측정값 880ms vs 70ms). 기동 중에 한 번 돌려서 그 비용을
        # /healthz 가 200 을 내기 전으로 옮긴다.
        from .startup_checks import _dummy_points

        t_warm = time.perf_counter()
        predictor.predict_windows([_dummy_points(art.window_size)])
        log.info("예열 완료 %.0fms", (time.perf_counter() - t_warm) * 1000)

        state.report = report
        state.predictor = predictor
        log.info(
            "모델 로드 완료 %.1fs version=%s",
            time.perf_counter() - t0,
            predictor.model_version,
        )
    except StartupCheckError as e:
        state.error = str(e)
        log.error("기동 검사 실패\n%s", e)
    except Exception as e:  # noqa: BLE001
        state.error = repr(e)
        log.exception("모델 로드 실패")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 별도 스레드에서 로드한다. 그래야 로드 중에도 /healthz 가 503 을 응답할 수
    # 있고, compose 헬스체크가 "응답 없음"이 아니라 "아직 준비 안 됨"을 본다.
    threading.Thread(target=_load, name="model-load", daemon=True).start()
    yield


app = FastAPI(title="bike-tracker inference", lifespan=lifespan)


# ── 요청/응답 스키마 (JSON 은 snake_case) ────────────────────────────────────
class Point(BaseModel):
    ts: int
    lat: float
    lng: float


class PredictRequest(BaseModel):
    session_id: str
    window_start_ts: int
    points: list[Point]


class PredictResponse(BaseModel):
    model_version: str
    label: str
    probs: dict[str, float]
    elapsed_ms: int


def _error(status: int, code: str, detail: str, retryable: bool) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={"error": code, "detail": detail, "retryable": retryable},
    )


def _not_ready() -> JSONResponse:
    if state.error:
        # 검사 실패는 재시도해도 낫지 않는다. 그래도 Spring 계약상 503 은
        # retryable 이므로, 사람이 볼 수 있게 detail 에 이유를 싣는다.
        return _error(503, "MODEL_NOT_READY", f"기동 검사 실패: {state.error}", False)
    return _error(503, "MODEL_NOT_READY", "모델 로드 중입니다", True)


def _predict_many(reqs: list[PredictRequest]):
    p = state.predictor
    windows = [[pt.model_dump() for pt in r.points] for r in reqs]
    t0 = time.perf_counter()
    with _infer_lock:
        labels, probs, _, _ = p.predict_windows(windows)
    elapsed = int((time.perf_counter() - t0) * 1000)
    per = max(elapsed // max(len(reqs), 1), 0)
    return [
        {
            "model_version": p.model_version,
            "label": labels[i],
            "probs": p.probs_to_dict(probs[i]),
            "elapsed_ms": per,
        }
        for i in range(len(reqs))
    ]


@app.post("/v1/predict")
def predict(req: PredictRequest):
    if state.predictor is None:
        return _not_ready()
    try:
        return _predict_many([req])[0]
    except WindowSizeError as e:
        return _error(422, "WINDOW_SIZE", str(e), False)
    except NonIncreasingTsError as e:
        return _error(422, "NON_INCREASING_TS", str(e), False)


@app.post("/v1/predict/batch")
def predict_batch(reqs: list[PredictRequest]):
    """
    요청 순서와 같은 순서의 배열로 응답한다. Spring 이 개수로 대조하므로
    중간에 하나가 잘못되면 부분 응답을 주지 않고 전체를 오류로 돌려준다.
    """
    if state.predictor is None:
        return _not_ready()
    if not reqs:
        return []
    if len(reqs) > MAX_BATCH_SIZE:
        log.warning(
            "배치 %d개는 권장 상한 %d개를 넘습니다. read timeout 30초에 걸릴 수 "
            "있으니 Spring 쪽에서 쪼개주세요.", len(reqs), MAX_BATCH_SIZE
        )
    try:
        return _predict_many(reqs)
    except WindowSizeError as e:
        return _error(422, "WINDOW_SIZE", str(e), False)
    except NonIncreasingTsError as e:
        return _error(422, "NON_INCREASING_TS", str(e), False)


@app.get("/v1/model")
def model_info():
    if state.predictor is None:
        return _not_ready()
    p = state.predictor
    a = p.art
    return {
        "model_version": p.model_version,
        "classes": a.le_classes,
        "window_size": a.window_size,
        "stride": a.stride,
        "accuracy_limit": a.accuracy_limit,
        "img_size": a.img_size,
        "n_features": len(a.feature_columns),
        "max_batch_size": MAX_BATCH_SIZE,
        "stop_threshold": a.stop_threshold,
        "tsfel_fs": a.tsfel_fs,
        "seg_gap_sec": a.seg_gap_sec,
        "sha256": {"pth": p.pth_sha256, "pkl": a.pkl_sha256},
        "versions_expected": a.versions,
        "versions_installed": {
            k: (md.version(v) if _safe(v) else None)
            for k, v in {
                "sklearn": "scikit-learn",
                "torch": "torch",
                "timm": "timm",
                "tsfel": "tsfel",
                "numpy": "numpy",
                "pandas": "pandas",
            }.items()
        },
        "startup_report": state.report,
    }


def _safe(dist: str) -> bool:
    try:
        md.version(dist)
        return True
    except Exception:
        return False


@app.get("/healthz")
def healthz():
    if state.predictor is None:
        return _not_ready()
    return {"status": "ok", "model_version": state.predictor.model_version}


@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    """
    pydantic 스키마 위반(필드 누락, 타입 오류)을 계약 형식으로 바꾼다.

    [주의] @app.exception_handler(422) 로는 잡히지 않는다. FastAPI 는 상태
    코드가 아니라 RequestValidationError 예외로 이 상황을 알리기 때문이다.
    잡지 않으면 기본 응답 {"detail": [...]} 이 나가고, Spring 의 Jackson 은
    error/retryable 을 찾지 못해 null 을 넣는다. 그러면 재시도 판단이
    엉뚱해진다.

    [코드 선택] 계약표에 있는 세 코드만 쓴다. Spring 이 enum 으로 받고 있다면
    새 코드는 역직렬화에서 깨진다. 스키마 위반도 '우리 쪽 버그'이므로
    retryable=false 인 WINDOW_SIZE 로 보내되, detail 에 진짜 원인을 적는다.
    """
    try:
        first = exc.errors()[0]
        where = ".".join(str(x) for x in first.get("loc", ())[1:]) or "body"
        why = first.get("msg", "invalid")
        detail = f"요청 본문이 계약과 다릅니다 ({where}: {why})"
    except Exception:  # noqa: BLE001
        detail = "요청 본문이 계약과 다릅니다"
    log.warning("스키마 위반 %s", detail)
    return _error(422, "WINDOW_SIZE", detail, False)
