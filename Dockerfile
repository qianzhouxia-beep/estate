# ============================================================
# CosyVoice 300M SFT - Zeabur 极速构建版
# ============================================================
# 核心策略：构建时不下模型，镜像 < 800MB，构建 < 5 分钟
# 模型在容器首次启动时后台静默下载
# ============================================================

FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# 最小系统依赖（无 ffmpeg/sox，模型推理不需要）
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

# 1. Clone CosyVoice 源码
RUN git clone --depth 1 --branch main https://github.com/FunAudioLLM/CosyVoice.git /tmp/CosyVoice && \
    cp -r /tmp/CosyVoice/cosyvoice /app/cosyvoice && \
    cp -r /tmp/CosyVoice/third_party /app/third_party && \
    rm -rf /tmp/CosyVoice /app/cosyvoice/.git /app/third_party/.git

# 2. 装 pip 依赖
COPY requirements.txt /app/requirements.txt
RUN pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip config set global.trusted-host mirrors.aliyun.com && \
    pip install --no-cache-dir -r /app/requirements.txt

# 3. 服务代码（不下模型！）
COPY server.py /app/server.py
COPY download_model.sh /app/download_model.sh
RUN mkdir -p /app/voices /app/pretrained_models /app/.cache && \
    chmod +x /app/download_model.sh

EXPOSE 8000

ENV PORT=8000
ENV VOICES_DIR=/app/voices
ENV MODEL_DIR=/app/pretrained_models/CosyVoice-300M-SFT
ENV PYTHONPATH=/app:$PYTHONPATH

# 启动脚本（处理首次启动下载 + 重试 + 健康检查）
RUN printf '#!/bin/bash\n\
set -e\n\
echo "⏳ Checking model at ${MODEL_DIR}..."\n\
if [ ! -f "${MODEL_DIR}/llm.pt" ] || [ ! -s "${MODEL_DIR}/llm.pt" ]; then\n\
  echo "📥 Model not found, starting download in background..."\n\
  bash /app/download_model.sh &\n\
fi\n\
echo "🚀 Starting server on port ${PORT:-8000}..."\n\
exec python3 -m uvicorn server:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --log-level info\n' > /app/start.sh && chmod +x /app/start.sh

CMD ["bash", "/app/start.sh"]
