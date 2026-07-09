# ============================================================
# CosyVoice 300M SFT - CPU 模式（超精简版）
# ============================================================
# 目标：Zeabur 2C 8G
# - 单阶段构建
# - 不含 ffmpeg/sox（CosyVoice 推理不需要）
# - 模型在构建时预下载（利用 Zeabur 构建缓存，避免运行时慢）
# ============================================================

FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# 最小系统依赖（砍掉 ffmpeg、sox，不装 GUI 库）
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    libsndfile1 \
    gcc \
    g++ \
    wget \
    curl \
    ca-certificates \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 1. Clone CosyVoice 源码（精简）
RUN git clone --depth 1 --branch main https://github.com/FunAudioLLM/CosyVoice.git /tmp/CosyVoice && \
    cp -r /tmp/CosyVoice/cosyvoice /app/cosyvoice && \
    cp -r /tmp/CosyVoice/third_party /app/third_party && \
    rm -rf /tmp/CosyVoice /app/cosyvoice/.git /app/third_party/.git

# 2. 装 pip 依赖
COPY requirements.txt /app/requirements.txt
RUN pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip config set global.trusted-host mirrors.aliyun.com && \
    pip install --no-cache-dir -r /app/requirements.txt

# 3. 服务代码和脚本
COPY server.py /app/server.py
COPY download_model.sh /app/download_model.sh
RUN mkdir -p /app/voices /app/pretrained_models /app/.cache && \
    chmod +x /app/download_model.sh

# 4. 【关键】构建时预下载模型（~2.2GB，利用构建缓存）
RUN bash /app/download_model.sh

# 5. 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

EXPOSE 8000

ENV PORT=8000
ENV VOICES_DIR=/app/voices
ENV MODEL_DIR=/app/pretrained_models/CosyVoice-300M-SFT
ENV PYTHONPATH=/app:$PYTHONPATH

# 启动入口（直接用 uvicorn，跳过下载）
CMD python3 -m uvicorn server:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --log-level info
