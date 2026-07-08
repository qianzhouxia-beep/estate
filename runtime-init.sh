#!/bin/bash
# CosyVoice 300M SFT - 启动脚本
# 1) 检查并下载模型（用 modelscope，失败则终止容器）
# 2) 启动 FastAPI 服务

set -e
echo "=========================================="
echo "CosyVoice 300M SFT - Starting..."
echo "Time: $(date)"
echo "=========================================="

# ---------- 1. 下载模型 ----------
# modelscope 会下载到 <cache>/iic/CosyVoice-300M-SFT 这样的路径
echo "[1/3] Checking / downloading model..."
python3 << 'PYEOF'
import os
os.environ['MODELSCOPE_CACHE'] = '/app/pretrained_models'
from modelscope import snapshot_download

model_dir = snapshot_download(
    'iic/CosyVoice-300M-SFT',
    cache_dir='/app/pretrained_models',
    revision='v1.1.0',
)
print(f"Model downloaded to: {model_dir}")

# 把路径写进 /tmp 供 server.py 启动时读
with open('/tmp/model_dir.txt', 'w') as f:
    f.write(model_dir)
print("Path written to /tmp/model_dir.txt")
PYEOF

# ---------- 2. 验证模型 ----------
echo "[2/3] Verifying model..."
if [ -f /tmp/model_dir.txt ]; then
    MODEL_DIR=$(cat /tmp/model_dir.txt)
    export MODEL_DIR
    echo "MODEL_DIR=${MODEL_DIR}"
    ls -la "${MODEL_DIR}" | head -20
else
    echo "ERROR: /tmp/model_dir.txt not found"
    exit 1
fi

# ---------- 3. 启动服务 ----------
echo "[3/3] Starting FastAPI server on port ${PORT:-8000}..."
cd /app
exec env MODEL_DIR="${MODEL_DIR}" python3 -m uvicorn server:app \
    --host 0.0.0.0 \
    --port ${PORT:-8000} \
    --workers 1 \
    --log-level info
