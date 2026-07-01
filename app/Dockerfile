FROM python:3.12-slim

ARG TARGETARCH=amd64

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${TARGETARCH}.zip" -o /tmp/rclone.zip \
    && unzip /tmp/rclone.zip -d /tmp/rclone \
    && cp /tmp/rclone/rclone-*-linux-${TARGETARCH}/rclone /usr/local/bin/rclone \
    && chmod 755 /usr/local/bin/rclone \
    && rm -rf /tmp/rclone /tmp/rclone.zip /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV GRADIO_SERVER_NAME=0.0.0.0 \
    GRADIO_SERVER_PORT=7860

EXPOSE 7860

CMD ["python", "main.py"]
