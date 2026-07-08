# CosyVoice 300M SFT - CPU 模式 Docker 镜像
# 目标：Zeabur 部署，2 核 8G 内存，零 GPU 依赖
# 构建时间：约 10-15 分钟（pip 装 torch + clone 模型）

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
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 1. 先 clone CosyVoice 源码（拿到 cosyvoice 包）
RUN git clone --depth 1 --branch main https://github.com/FunAudioLLM/CosyVoice.git /tmp/CosyVoice && \
    cp -r /tmp/CosyVoice/cosyvoice /app/cosyvoice && \
    cp -r /tmp/CosyVoice/third_party /app/third_party && \
    rm -rf /tmp/CosyVoice

# 2. 装依赖（用国内镜像加速）
COPY requirements.txt /app/requirements.txt
RUN pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip config set global.trusted-host mirrors.aliyun.com && \
    pip install --no-cache-dir -r /app/requirements.txt

# 3. 装 cosyvoice 依赖（runtime + frontend + backend）
# cosyvoice 包内的 requirements.txt
RUN pip install --no-cache-dir \
    "modelscope==1.18.1" \
    "tokenizers==0.19.1" \
    "openai-whisper" \
    "WeTextProcessing" \
    "rotary_embedding_torch" \
    || true

# 4. 下载 CosyVoice 300M SFT 模型（从 ModelScope，国内可访问）
# 也支持从 HuggingFace：FunAudioLLM/CosyVoice-300M-SFT
RUN mkdir -p /app/pretrained_models && \
    cd /app/pretrained_models && \
    echo "Downloading CosyVoice-300M-SFT model (~1.2GB)..." && \
    python -c "from modelscope import snapshot_download; snapshot_download('iic/CosyVoice-300M-SFT', local_dir='/app/pretrained_models/CosyVoice-300M-SFT')" \
    || (echo "ModelScope failed, trying HuggingFace..." && \
        python -c "from huggingface_hub import snapshot_download; snapshot_download('FunAudioLLM/CosyVoice-300M-SFT', local_dir='/app/pretrained_models/CosyVoice-300M-SFT')")

# 5. 拷贝项目代码
COPY server.py /app/server.py

# 6. 创建音色目录
RUN mkdir -p /app/voices

# 7. 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

# 8. 启动
EXPOSE 8000
ENV PORT=8000
ENV VOICES_DIR=/app/voices
ENV MODEL_DIR=/app/pretrained_models/CosyVoice-300M-SFT

CMD ["python", "server.py"]
