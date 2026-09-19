# inference-fastapi

bike-tracker Python 추론 서버. 계약은 인수인계 문서 2절.

## 로컬 실행

    pip install -r requirements.txt
    MODEL_DIR=./models uvicorn app.main:app --port 8000

## 검증

    python tests/test_parity.py   # 학습-서버 일치 (골든셋 11개)
    python tests/test_api.py      # 계약 + 오류 경로 (15항목)

## 실 주행 재생

폰 CSV 를 Spring 규칙대로 잘라 추론까지 돌리고, bike 궤적이 몇 번
끊기는지 보여줍니다. 겹침 규칙 세 가지를 바꿔가며 비교할 수 있습니다.

    python tools/replay_csv.py trip.csv
    python tools/replay_csv.py trip.csv --strategy STRICT_BIKE

## 건드리면 안 되는 곳

- `pipeline.py` 의 함수 본문. 학습 코드 그대로입니다.
- `extract_tsfel_features` 의 `except Exception: continue`.
  학습 환경에서 spectral 도메인이 매번 실패했고 FEATURE_COLUMNS 에도
  spectral 컬럼이 없습니다. 이걸 '고치면' 학습에 없던 컬럼이 생깁니다.
- 클래스 인덱스. 항상 pkl 의 `le_classes` 에서 읽습니다.
