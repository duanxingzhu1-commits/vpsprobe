FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY server.py index.html ./
RUN mkdir -p /data && chown 10001:10001 /data /app
USER 10001:10001
EXPOSE 8765
CMD ["python3", "server.py"]

