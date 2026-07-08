#!/bin/bash
# CosyVoice 300M SFT 模型下载（纯 wget，不用 modelscope/huggingface_hub）
# 模型源：HuggingFace 镜像 https://hf-mirror.com

set -e
MODEL_DIR="/app/pretrained_models/CosyVoice-300M-SFT"
mkdir -p "$MODEL_DIR"

# 检查是否已下载
if [ -f "$MODEL_DIR/cosyvoice.yaml" ]; then
    echo "Model already exists at $MODEL_DIR"
    echo "$MODEL_DIR" > /tmp/model_dir.txt
    exit 0
fi

# 下载源（用 HF 镜像，国内可访问）
BASE="https://hf-mirror.com/FunAudioLLM/CosyVoice-300M-SFT/resolve/main"

cd "$MODEL_DIR"

# 必要文件列表（与官方一致）
FILES=(
    "cosyvoice.yaml"
    "flow.yaml"
    "hift.yaml"
    "mel_cache.yaml"
    "hifigan.yaml"
    "cosyvoice.onnx"
    "flow.onnx"
    "hift.onnx"
    "campplus.onnx"
    "speech_tokenizer_v1.onnx"
    "spk2info.pt"
    "token.pt"
)

for f in "${FILES[@]}"; do
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
        echo "Downloading $f..."
        wget -q --show-progress --tries=3 --timeout=60 \
            "$BASE/$f" -O "$f" \
            || echo "  ⚠️ Failed: $f (will retry next start)"
    else
        echo "  ✓ $f ($(du -h $f | cut -f1))"
    fi
done

cd /app

# 写入路径供 server.py 读
echo "$MODEL_DIR" > /tmp/model_dir.txt
echo "✅ Model download complete. Path: $MODEL_DIR"
ls -la "$MODEL_DIR"
