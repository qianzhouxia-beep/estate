#!/bin/bash
# CosyVoice 300M SFT 模型下载（纯 wget）
# 源：HuggingFace 镜像 https://hf-mirror.com/FunAudioLLM/CosyVoice-300M-SFT

set -e
MODEL_DIR="/app/pretrained_models/CosyVoice-300M-SFT"
mkdir -p "$MODEL_DIR"

# 检查是否已下载（看核心文件 llm.pt）
if [ -f "$MODEL_DIR/llm.pt" ] && [ -s "$MODEL_DIR/llm.pt" ]; then
    echo "✅ Model already exists at $MODEL_DIR"
    echo "$MODEL_DIR" > /tmp/model_dir.txt
    ls -la "$MODEL_DIR"
    exit 0
fi

# 下载源（用 HF 镜像，国内可访问）
BASE="https://hf-mirror.com/FunAudioLLM/CosyVoice-300M-SFT/resolve/main"

cd "$MODEL_DIR"

# 必要文件清单（实际 HF 仓库文件）
# 小文件 < 10MB
SMALL_FILES=(
    "cosyvoice.yaml"
    "config.json"
    "configuration.json"
    "campplus.onnx"
    "speech_tokenizer_v1.onnx"
    "spk2info.pt"
)

# 大文件（>50MB，按顺序下）
LARGE_FILES=(
    "flow.pt"          # 420MB
    "hift.pt"          # 82MB
    "llm.pt"           # 1.2GB（核心）
)

echo "[1/2] Downloading small files..."
for f in "${SMALL_FILES[@]}"; do
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
        echo "  → $f"
        wget -q --tries=3 --timeout=60 \
            "$BASE/$f" -O "$f.tmp" \
            && mv "$f.tmp" "$f" \
            || echo "  ⚠️ Failed: $f"
    else
        echo "  ✓ $f ($(du -h $f | cut -f1))"
    fi
done

echo "[2/2] Downloading large files (this may take 5-10 minutes)..."
for f in "${LARGE_FILES[@]}"; do
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
        echo "  → $f (large file, please wait...)"
        wget --tries=3 --timeout=300 \
            "$BASE/$f" -O "$f.tmp" 2>&1 | tail -3
        if [ -s "$f.tmp" ]; then
            mv "$f.tmp" "$f"
            echo "  ✓ $f ($(du -h $f | cut -f1))"
        else
            echo "  ⚠️ Failed: $f"
            rm -f "$f.tmp"
        fi
    else
        echo "  ✓ $f ($(du -h $f | cut -f1))"
    fi
done

cd /app

# 检查关键文件
echo ""
echo "=========================================="
echo "Final model directory:"
ls -la "$MODEL_DIR"
echo "=========================================="

if [ ! -f "$MODEL_DIR/llm.pt" ]; then
    echo "❌ ERROR: llm.pt not found, model download failed"
    exit 1
fi

echo "$MODEL_DIR" > /tmp/model_dir.txt
echo "✅ Model download complete. Path: $MODEL_DIR"
