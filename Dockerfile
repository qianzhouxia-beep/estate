# ============================================================
# CosyVoice 300M SFT - CPU 模式（多阶段，build 不下模型）
# ============================================================
# Stage 1: builder - 装所有 pip 包（不打包到最终镜像）
# Stage 2: runtime - 仅含运行所需 + CosyVoice 源码
# 模型在容器启动时下载（runtime-init.sh）
# ============================================================

# ---------- Stage 1: builder ----------
FROM python:3.10-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
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
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone CosyVoice（不带 submodule，避免占空间）
RUN git clone --depth 1 --branch main https://github.com/FunAudioLLM/CosyVoice.git /build/CosyVoice && \
    rm -rf /build/CosyVoice/.git && \
    rm -rf /build/CosyVoice/webui /build/CosyVoice/assets /build/CosyVoice/runtime/python /build/CosyVoice/docs && \
    rm -rf /build/CosyVoice/.github /build/CosyVoice/test /build/CosyVoice/examples

# 装依赖到 /install（用 pypi 国内镜像）
COPY requirements.txt /build/requirements.txt
RUN pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip config set global.trusted-host mirrors.aliyun.com && \
    pip install --prefix=/install --no-cache-dir -r /build/requirements.txt


# ---------- Stage 2: runtime ----------
FROM python:3.10-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# 运行时系统依赖（精简：去掉 gcc/cmake 等编译工具）
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    sox \
    ffmpeg \
    libsndfile1 \
    wget \
    curl \
    ca-certificates \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 从 builder 复制 Python 包（只保留运行时）
COPY --from=builder /install/usr/local/lib/python3.10/site-packages /usr/local/lib/python3.10/site-packages
COPY --from=builder /install/usr/local/bin /usr/local/bin

# 复制 CosyVoice 源码（精简版）
COPY --from=builder /build/CosyVoice/cosyvoice /app/cosyvoice
COPY --from=builder /build/CosyVoice/third_party /app/third_party

# 启动脚本 + 服务代码
COPY runtime-init.sh /app/runtime-init.sh
COPY server.py /app/server.py
RUN mkdir -p /app/voices /app/pretrained_models /app/.cache && \
    chmod +x /app/runtime-init.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

EXPOSE 8000

ENV PORT=8000
ENV VOICES_DIR=/app/voices
ENV MODEL_DIR=/app/pretrained_models/CosyVoice-300M-SFT
ENV PYTHONPATH=/app:$PYTHONPATH

# 启动入口
CMD ["/app/runtime-init.sh"]
