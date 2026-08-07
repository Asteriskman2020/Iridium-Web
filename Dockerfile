FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/

# Messages and settings live in a volume so redeploys keep history.
ENV DB_PATH=/data/iridium.db
VOLUME ["/data"]

EXPOSE 8899

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8899/healthz || exit 1

# ONE worker, many threads. Threads still keep the 3-second RockBLOCK webhook
# deadline comfortably, and a single process means a single MQTT client: with
# two workers both would subscribe to the command topic, so one inbound "send"
# would be handled twice and spend two Iridium credits.
CMD ["gunicorn", "-w", "1", "--threads", "8", "-b", "0.0.0.0:8899", \
     "--access-logfile", "-", "--error-logfile", "-", "app:app"]
