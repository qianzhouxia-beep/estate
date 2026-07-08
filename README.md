# CosyVoice Estate（房视界AI 声音克隆服务）

部署在 Zeabur（新加坡 8G），为房视界AI SaaS 提供零样本声音克隆 + TTS 接口。

## 接口

- `GET /health` — 健康检查
- `GET /voices` — 列出已保存音色
- `POST /voice/clone` — 上传参考音频注册音色（multipart）
- `POST /tts` — 用指定音色合成语音，返回 WAV
- `DELETE /voice/{voice_id}` — 删除音色

## 环境变量

- `ALLOWED_IPS` — 逗号分隔的 IP 白名单（推荐设置成上海服务器 IP）
- `PORT` — 监听端口（默认 8000）
- `MODEL_DIR` — 模型目录（默认 `/app/pretrained_models/CosyVoice-300M-SFT`）
- `VOICES_DIR` — 音色保存目录（默认 `/app/voices`）

## 上海服务器调用

```python
import requests
url = "https://cosyvoice-estate.zeabur.app"
# 1. 注册音色
requests.post(f"{url}/voice/clone", files={"audio": open("ref.wav","rb")}, data={"voice_id":"agent1"})
# 2. 合成
r = requests.post(f"{url}/tts", json={"text":"您好","voice_id":"agent1"})
with open("out.wav","wb") as f: f.write(r.content)
```
