"""
CosyVoice CPU-only HTTP API server (lazy model loading)
- 端口: 8000
- 接口:
  - GET  /health              健康检查 + 模型状态
  - GET  /voices              列出可用音色
  - POST /voice/clone         注册零样本音色
  - POST /tts                 声音克隆 + TTS
- 安全: ALLOWED_IPS 白名单
- 模型初始化: 懒加载（首次 /tts 请求时加载，构建时可不下模型）
"""
import os
import io
import re
import time
import json
import logging
import base64
import hashlib
import threading
from typing import Optional, List

import torch
import numpy as np
from fastapi import FastAPI, HTTPException, Request, UploadFile, File, Form
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
import soundfile as sf

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("cosyvoice-server")

# ---------- 配置 ----------
ALLOWED_IPS = set(
    ip.strip() for ip in os.environ.get("ALLOWED_IPS", "").split(",") if ip.strip()
)
VOICES_DIR = os.environ.get("VOICES_DIR", "/app/voices")
SAMPLE_RATE = 22050

os.makedirs(VOICES_DIR, exist_ok=True)

# ---------- 懒加载模型 ----------
_model = None
_model_lock = threading.Lock()
_model_loading = False


def _resolve_model_dir():
    """确定模型路径"""
    # 1. /tmp/model_dir.txt（runtime-init 写入）
    if os.path.exists("/tmp/model_dir.txt"):
        with open("/tmp/model_dir.txt") as f:
            path = f.read().strip()
        if path and os.path.exists(path):
            return path
    # 2. 环境变量
    env_path = os.environ.get("MODEL_DIR", "")
    if env_path and os.path.exists(env_path):
        return env_path
    # 3. 默认
    default = os.environ.get("MODEL_DIR", "pretrained_models/CosyVoice-300M-SFT")
    if os.path.exists(default):
        return default
    return default


def load_model(force: bool = False):
    """线程安全懒加载模型"""
    global _model, _model_loading
    if _model is not None and not force:
        return _model
    if _model_loading and not force:
        raise RuntimeError("Model is currently being loaded, please retry later")

    with _model_lock:
        if _model is not None and not force:
            return _model
        if _model_loading and not force:
            raise RuntimeError("Model is currently being loaded, please retry later")
        _model_loading = True

    try:
        model_dir = _resolve_model_dir()
        if not os.path.exists(model_dir):
            raise FileNotFoundError(f"Model directory not found: {model_dir}")
        if not os.path.exists(os.path.join(model_dir, "llm.pt")):
            raise FileNotFoundError(
                f"llm.pt not found in {model_dir}. "
                "Download model first:\n"
                "  bash download_model.sh"
            )

        logger.info(f"Loading CosyVoice model from {model_dir}...")
        load_start = time.time()

        from cosyvoice.cli.cosyvoice import AutoModel

        _model = AutoModel(model_dir=model_dir)
        logger.info(f"✅ Model loaded in {time.time() - load_start:.1f}s")
    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        _model = None
        raise
    finally:
        _model_loading = False

    return _model


def is_model_ready() -> bool:
    return _model is not None


# ---------- IP 白名单中间件 ----------
app = FastAPI(title="CosyVoice Server", version="2.0.0")


@app.middleware("http")
async def ip_whitelist(request: Request, call_next):
    if request.url.path in ("/health", "/"):
        return await call_next(request)
    if not ALLOWED_IPS:
        logger.warning("ALLOWED_IPS not configured, allowing all IPs (DEV mode)")
        return await call_next(request)
    client_ip = request.client.host if request.client else "unknown"
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


# ---------- 数据模型 ----------
class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=1000, description="要合成的文本")
    voice_id: str = Field(..., description="音色 ID（已保存的零样本音色）")
    speed: float = Field(1.0, ge=0.5, le=2.0, description="语速")


# ---------- 工具函数 ----------
def _normalize_voice_id(voice_id: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9_-]", "", voice_id)
    if not safe or len(safe) > 64:
        raise HTTPException(status_code=400, detail="invalid voice_id")
    return safe


def _voice_path(voice_id: str) -> str:
    return os.path.join(VOICES_DIR, f"{_normalize_voice_id(voice_id)}.wav")


def list_voices() -> list:
    return [f[:-4] for f in os.listdir(VOICES_DIR) if f.endswith(".wav")]


def _save_voice(voice_id: str, audio_bytes: bytes) -> str:
    """保存零样本音色 WAV，自动重采样到 16kHz"""
    path = _voice_path(voice_id)
    try:
        data, sr = sf.read(io.BytesIO(audio_bytes))
        if sr != 16000:
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
    return {
        "name": "CosyVoice Server",
        "version": "2.0.0",
        "model_ready": is_model_ready(),
    }


@app.get("/health")
async def health():
    # 检查模型文件是否可加载
    model_dir = _resolve_model_dir()
    model_files_ok = os.path.exists(os.path.join(model_dir, "llm.pt")) if model_dir else False

    return {
        "status": "ok" if is_model_ready() else "loading",
        "model_ready": is_model_ready(),
        "model_dir": model_dir,
        "model_files_exist": model_files_ok,
        "voices_count": len(list_voices()),
        "allowed_ips_configured": len(ALLOWED_IPS) > 0,
    }


@app.get("/voices")
async def voices():
    return {"voices": list_voices(), "count": len(list_voices())}


@app.post("/voice/clone")
async def clone_voice(
    voice_id: str = Form(..., min_length=1, max_length=64),
    audio: UploadFile = File(..., description="参考音频 WAV/MP3，5-30 秒"),
    description: str = Form("", max_length=200),
):
    """注册零样本声音克隆音色"""
    voice_id = _normalize_voice_id(voice_id)
    if voice_id in list_voices():
        raise HTTPException(status_code=409, detail=f"voice_id '{voice_id}' already exists")

    audio_bytes = await audio.read()
    if len(audio_bytes) > 10 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="audio file too large (max 10MB)")

    path = _save_voice(voice_id, audio_bytes)

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
    """声音克隆 + 合成（懒加载模型）"""
    # 1. 检查音色
    voice_id = _normalize_voice_id(req.voice_id)
    prompt_path = _voice_path(voice_id)
    if not os.path.exists(prompt_path):
        raise HTTPException(
            status_code=404,
            detail=f"voice '{voice_id}' not found, please clone first",
        )

    # 2. 确保模型已加载（懒加载）
    try:
        mdl = load_model()
    except FileNotFoundError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        logger.exception(f"Model load failed: {e}")
        raise HTTPException(status_code=500, detail=f"Model load error: {str(e)}")

    # 3. TTS 推理
    try:
        start = time.time()

        from cosyvoice.utils.file_utils import load_wav

        result = mdl.inference_zero_shot(
            tts_text=req.text,
            prompt_text="",
            prompt_speech_16k=load_wav(prompt_path, 16000),
            speed=req.speed,
        )

        wav_data = None
        for item in result:
            wav_data = item["tts_speech"]
            break

        if wav_data is None:
            raise HTTPException(status_code=500, detail="model returned no audio")

        if isinstance(wav_data, torch.Tensor):
            wav_data = wav_data.cpu().numpy()
        wav_data = np.array(wav_data).astype(np.float32)

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
