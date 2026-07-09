"""
CosyVoice CPU-only HTTP API server
- 端口: 8000
- 接口:
  - GET  /health              健康检查
  - GET  /voices              列出可用音色
  - POST /tts                 零样本声音克隆 + TTS
  - POST /tts/text            纯 TTS（用已保存的音色）
- 安全: 只接受 ALLOWED_IPS 中的 IP 访问（通过环境变量配置）
"""
import os
import io
import re
import time
import json
import logging
import base64
import hashlib
import tempfile
from typing import Optional, List

import torch
import numpy as np
from fastapi import FastAPI, HTTPException, Request, UploadFile, File, Form
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
import soundfile as sf
from cosyvoice.cli.cosyvoice import AutoModel
from cosyvoice.utils.file_utils import load_wav

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("cosyvoice-server")

# ---------- 配置 ----------
ALLOWED_IPS = set(
    ip.strip() for ip in os.environ.get("ALLOWED_IPS", "").split(",") if ip.strip()
)
VOICES_DIR = os.environ.get("VOICES_DIR", "/app/voices")
SAMPLE_RATE = 22050

# 模型路径优先级：1) /tmp/model_dir.txt（runtime-init 写入） 2) 环境变量 3) 默认
def _resolve_model_dir():
    if os.path.exists("/tmp/model_dir.txt"):
        with open("/tmp/model_dir.txt") as f:
            path = f.read().strip()
        if path and os.path.exists(path):
            return path
    return os.environ.get("MODEL_DIR", "pretrained_models/CosyVoice-300M-SFT")

MODEL_DIR = _resolve_model_dir()

os.makedirs(VOICES_DIR, exist_ok=True)

# ---------- IP 白名单中间件 ----------
app = FastAPI(title="CosyVoice Server", version="1.0.0")


@app.middleware("http")
async def ip_whitelist(request: Request, call_next):
    # 放行本地健康检查
    if request.url.path in ("/health", "/"):
        return await call_next(request)
    if not ALLOWED_IPS:
        # 没配置白名单 → 放行（开发模式），生产必须配置
        logger.warning("ALLOWED_IPS not configured, allowing all IPs (DEV mode)")
        return await call_next(request)
    client_ip = request.client.host if request.client else "unknown"
    # 处理 X-Forwarded-For（Zeabur 走反代）
    xff = request.headers.get("x-forwarded-for")
    if xff:
        client_ip = xff.split(",")[0].strip()
    if client_ip not in ALLOWED_IPS:
        logger.warning(f"Blocked request from {client_ip} to {request.url.path}")
        return JSONResponse(
            status_code=403,
            content={"error": "forbidden", "message": f"IP {client_ip} not allowed"},
        )
    return await call_next(request)


# ---------- 模型加载 ----------
logger.info(f"Loading CosyVoice model from {MODEL_DIR}...")
load_start = time.time()
try:
    model = AutoModel(model_dir=MODEL_DIR)
    logger.info(f"Model loaded in {time.time() - load_start:.1f}s")
except Exception as e:
    logger.error(f"Failed to load model from {MODEL_DIR}: {e}")
    # 打印 /app/pretrained_models 内容帮助调试
    if os.path.exists("/app/pretrained_models"):
        logger.error(f"/app/pretrained_models contents: {os.listdir('/app/pretrained_models')}")
        for root, dirs, files in os.walk("/app/pretrained_models"):
            for f in files:
                logger.error(f"  {os.path.join(root, f)}")
    raise


# ---------- 数据模型 ----------
class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=1000, description="要合成的文本")
    voice_id: str = Field(..., description="音色 ID（已保存的零样本音色）")
    speed: float = Field(1.0, ge=0.5, le=2.0, description="语速")


# ---------- 工具函数 ----------
def _normalize_voice_id(voice_id: str) -> str:
    """安全化 voice_id，避免路径穿越"""
    safe = re.sub(r"[^a-zA-Z0-9_-]", "", voice_id)
    if not safe or len(safe) > 64:
        raise HTTPException(status_code=400, detail="invalid voice_id")
    return safe


def _voice_path(voice_id: str) -> str:
    return os.path.join(VOICES_DIR, f"{_normalize_voice_id(voice_id)}.wav")


def _save_voice(voice_id: str, audio_bytes: bytes) -> str:
    """保存零样本音色 WAV"""
    path = _voice_path(voice_id)
    # 校验是合法 WAV
    try:
        data, sr = sf.read(io.BytesIO(audio_bytes))
        if sr != 16000:
            # 重采样到 16kHz（CosyVoice 要求）
            import scipy.signal as sps
            duration = len(data) / sr
            new_len = int(duration * 16000)
            data = sps.resample(data, new_len)
        sf.write(path, data, 16000, subtype="PCM_16")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"invalid audio file: {e}")
    return path


# ---------- 接口 ----------
@app.get("/")
async def root():
    return {"name": "CosyVoice Server", "version": "1.0.0", "model": MODEL_DIR}


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model_loaded": True,
        "model_dir": MODEL_DIR,
        "voices_count": len(list_voices()),
        "allowed_ips_configured": len(ALLOWED_IPS) > 0,
    }


@app.get("/voices")
async def voices():
    vs = [f[:-4] for f in os.listdir(VOICES_DIR) if f.endswith(".wav")]
    return {"voices": vs, "count": len(vs)}


@app.post("/voice/clone")
async def clone_voice(
    voice_id: str = Form(..., min_length=1, max_length=64),
    audio: UploadFile = File(..., description="参考音频 WAV/MP3，5-30 秒"),
    description: str = Form("", max_length=200),
):
    """注册零样本声音克隆音色
    上传一段 5-30 秒的清晰人声 → 保存为 voice_id
    """
    voice_id = _normalize_voice_id(voice_id)
    if voice_id in list_voices():
        raise HTTPException(status_code=409, detail=f"voice_id '{voice_id}' already exists")

    audio_bytes = await audio.read()
    if len(audio_bytes) > 10 * 1024 * 1024:  # 10MB 上限
        raise HTTPException(status_code=413, detail="audio file too large (max 10MB)")

    path = _save_voice(voice_id, audio_bytes)

    # 保存元信息
    meta_path = path + ".meta.json"
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump({
            "voice_id": voice_id,
            "description": description,
            "created_at": int(time.time()),
            "size_bytes": len(audio_bytes),
            "filename": audio.filename or "",
        }, f, ensure_ascii=False, indent=2)

    logger.info(f"Voice cloned: {voice_id} ({len(audio_bytes)} bytes)")
    return {"voice_id": voice_id, "path": path, "size_bytes": len(audio_bytes)}


@app.delete("/voice/{voice_id}")
async def delete_voice(voice_id: str):
    voice_id = _normalize_voice_id(voice_id)
    path = _voice_path(voice_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="voice not found")
    os.remove(path)
    meta = path + ".meta.json"
    if os.path.exists(meta):
        os.remove(meta)
    return {"deleted": voice_id}


@app.post("/tts")
async def tts(req: TTSRequest):
    """声音克隆 + 合成
    文本 → 用指定 voice_id 的音色 → 返回 WAV
    """
    voice_id = _normalize_voice_id(req.voice_id)
    prompt_path = _voice_path(voice_id)
    if not os.path.exists(prompt_path):
        raise HTTPException(status_code=404, detail=f"voice '{voice_id}' not found, please clone first")

    try:
        # CosyVoice 推理
        start = time.time()
        result = model.inference_zero_shot(
            tts_text=req.text,
            prompt_text="",  # 零样本模式不需要 prompt_text
            prompt_speech_16k=load_wav(prompt_path, 16000),
            speed=req.speed,
        )
        # result 是生成器，yield 一个 dict
        wav_data = None
        for item in result:
            wav_data = item["tts_speech"]
            break

        if wav_data is None:
            raise HTTPException(status_code=500, detail="model returned no audio")

        # 转 numpy
        if isinstance(wav_data, torch.Tensor):
            wav_data = wav_data.cpu().numpy()
        wav_data = np.array(wav_data).astype(np.float32)

        # 编码为 WAV bytes
        buf = io.BytesIO()
        sf.write(buf, wav_data, SAMPLE_RATE, subtype="PCM_16")
        buf.seek(0)
        wav_bytes = buf.read()

        duration = len(wav_data) / SAMPLE_RATE
        logger.info(
            f"TTS done: voice={voice_id}, text_len={len(req.text)}, "
            f"audio={duration:.1f}s, cost={time.time() - start:.2f}s"
        )
        return Response(content=wav_bytes, media_type="audio/wav", headers={
            "X-Audio-Duration": f"{duration:.2f}",
            "X-Voice-Id": voice_id,
        })
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(f"TTS failed: {e}")
        raise HTTPException(status_code=500, detail=f"TTS error: {str(e)}")


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    logger.info(f"Starting server on 0.0.0.0:{port}")
    uvicorn.run("server:app", host="0.0.0.0", port=port, log_level="info")
