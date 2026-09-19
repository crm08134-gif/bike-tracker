"""계약 · 오류 경로 검증 (계획서 6절 '오류 경로').

    python tests/test_api.py
"""
import json, os, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault("MODEL_DIR", str(ROOT / "models"))
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient
from app.main import app, state

reqs = json.loads((ROOT / "golden" / "golden_requests.json").read_text())
PASS, FAIL = [], []


def check(name, cond, note=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'OK  ' if cond else 'FAIL'} {name}{'  ' + note if note else ''}")


def clone(i=0):
    return json.loads(json.dumps(reqs[i]["request"]))


with TestClient(app) as c:
    for _ in range(240):
        if state.predictor or state.error:
            break
        time.sleep(0.5)
    assert state.predictor, f"모델 로드 실패: {state.error}"

    print("\n[정상 경로]")
    r = c.get("/healthz")
    check("healthz 200", r.status_code == 200)

    m = c.get("/v1/model").json()
    check("model 응답", m["classes"] == ["bike", "bus", "car", "subway", "walk"],
          f"window={m['window_size']} stride={m['stride']} acc={m['accuracy_limit']}")

    ok = c.post("/v1/predict", json=clone()).json()
    check("predict 5클래스 확률", len(ok["probs"]) == 5, f"{ok['label']} {ok['elapsed_ms']}ms")
    check("확률 합 1", abs(sum(ok["probs"].values()) - 1) < 1e-4)

    b = c.post("/v1/predict/batch", json=[x["request"] for x in reqs]).json()
    check("batch 길이·순서 보존", len(b) == len(reqs))
    check("batch == 단건", b[0]["label"] == ok["label"])

    print("\n[오류 경로 — 계약 2절]")
    bad = clone(); bad["points"] = bad["points"][:199]
    r = c.post("/v1/predict", json=bad); j = r.json()
    check("199점 → 422 WINDOW_SIZE",
          r.status_code == 422 and j["error"] == "WINDOW_SIZE" and j["retryable"] is False)

    dup = clone(); dup["points"][5]["ts"] = dup["points"][4]["ts"]
    r = c.post("/v1/predict", json=dup); j = r.json()
    check("ts 중복 → 422 NON_INCREASING_TS",
          r.status_code == 422 and j["error"] == "NON_INCREASING_TS" and j["retryable"] is False)

    rev = clone(); rev["points"][7]["ts"] = rev["points"][6]["ts"] - 1000
    r = c.post("/v1/predict", json=rev)
    check("ts 역행 → 422 NON_INCREASING_TS", r.json()["error"] == "NON_INCREASING_TS")

    print("\n[오류 경로 — 스키마 위반도 계약 형식이어야 함]")
    for name, mut in [
        ("lat 누락", lambda x: x["points"][3].pop("lat")),
        ("session_id 누락", lambda x: x.pop("session_id")),
        ("ts 가 문자열", lambda x: x["points"][3].__setitem__("ts", "abc")),
        ("points 누락", lambda x: x.pop("points")),
    ]:
        x = clone(); mut(x)
        j = c.post("/v1/predict", json=x).json()
        check(f"{name} → 계약 형식",
              j.get("error") == "WINDOW_SIZE" and j.get("retryable") is False)

    print("\n[모델 미로드]")
    saved, state.predictor = state.predictor, None
    r = c.get("/healthz"); j = r.json()
    check("healthz 503 MODEL_NOT_READY",
          r.status_code == 503 and j["error"] == "MODEL_NOT_READY" and j["retryable"] is True)
    r = c.post("/v1/predict", json=clone())
    check("predict 503 retryable", r.status_code == 503 and r.json()["retryable"] is True)
    state.predictor = saved

print(f"\n통과 {len(PASS)} / 실패 {len(FAIL)}")
if FAIL:
    print("실패:", FAIL)
    sys.exit(1)
print("API PASS")
