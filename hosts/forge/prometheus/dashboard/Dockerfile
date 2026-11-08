FROM python:3.13-alpine@sha256:1e1f6334529d1fb26a2ef619d7cffb30a7c7d7cc1cc7338ebee283a58d1aeaca
WORKDIR /app
COPY server.py index.html ./
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65532:65532
CMD ["python", "server.py"]
