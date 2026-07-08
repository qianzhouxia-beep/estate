# ============================================================
# CosyVoice 300M SFT - CPU 模式（精简版，build 只装必需 pip 包）
# ============================================================
# 目标：Zeabur 2C 8G
# - 单阶段（避免多阶段 COPY 失败）
# - build 阶段只装 pip 包，不下模型
# - 模型在启动时用 wget 直链下载（不需要 huggingface_hub/modelscope）
# ============================================================

FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# 系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    sox \
    ffmpeg \
    libsndfile1 \
    gcc \
    g++ \
    make \
    cmake \
    wget \
    curl \
    ca-certificates \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 1. Clone CosyVoice 源码（精简：删除不必要目录）
RUN git clone --depth 1 --branch main https://github.com/FunAudioLLM/CosyVoice.git /tmp/CosyVoice && \
    cp -r /tmp/CosyVoice/cosyvoice /app/cosyvoice && \
    cp -r /tmp/CosyVoice/third_party /app/third_party && \
    rm -rf /tmp/CosyVoice /app/cosyvoice/.git /app/third_party/.git

# 2. 装核心依赖（不装 modelscope/huggingface_hub，启动时用 wget）
COPY requirements.txt /app/requirements.txt
RUN pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip config set global.trusted-host mirrors.aliyun.com && \
    pip install --no-cache-dir -r /app/requirements.txt

# 3. 启动脚本 + 服务代码
COPY runtime-init.sh /app/runtime-init.sh
COPY server.py /app/server.py
COPY download_model.sh /app/download_model.sh
RUN mkdir -p /app/voices /app/pretrained_models /app/.cache && \
    chmod +x /app/runtime-init.sh /app/download_model.sh

# 4. 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

EXPOSE 8000

ENV PORT=8000
ENV VOICES_DIR=/app/voices
ENV MODEL_DIR=/app/pretrained_models/CosyVoice-300M-SFT
ENV PYTHONPATH=/app:$PYTHONPATH

# 启动入口
CMD ["/app/runtime-init.sh"]
