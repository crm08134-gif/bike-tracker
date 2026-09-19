FROM python:3.12-slim

# curl 은 compose 헬스체크가 컨테이너 안에서 실행합니다 (계획서 5절)
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

ENV MODEL_DIR=/app/models \
    TORCH_NUM_THREADS=2 \
    PYTHONUNBUFFERED=1

# models/ 는 이미지에 넣지 않고 compose 볼륨으로 읽기 전용 마운트합니다
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
