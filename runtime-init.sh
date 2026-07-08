#!/bin/bash
# CosyVoice 启动脚本
# 1) 下载模型（如果还没下）
# 2) 启动 FastAPI

set -e
echo "=========================================="
echo "CosyVoice 300M SFT - Starting..."
echo "Time: $(date)"
echo "=========================================="

# ---------- 1. 下载模型 ----------
echo "[1/3] Checking model..."
bash /app/download_model.sh

# ---------- 2. 验证模型 ----------
echo "[2/3] Verifying model..."
if [ -f /tmp/model_dir.txt ]; then
    MODEL_DIR=$(cat /tmp/model_dir.txt)
    export MODEL_DIR
    echo "MODEL_DIR=${MODEL_DIR}"
    echo "Files in model dir:"
    ls -la "${MODEL_DIR}" 2>&1 | head -25

    if [ ! -f "${MODEL_DIR}/cosyvoice.yaml" ]; then
        echo "❌ ERROR: cosyvoice.yaml not found in ${MODEL_DIR}"
        exit 1
    fi
else
    echo "❌ ERROR: /tmp/model_dir.txt not found"
    exit 1
fi

# ---------- 3. 启动服务 ----------
echo "[3/3] Starting FastAPI server on port ${PORT:-8000}..."
cd /app
exec python3 -m uvicorn server:app \
    --host 0.0.0.0 \
    --port ${PORT:-8000} \
    --workers 1 \
    --log-level info
