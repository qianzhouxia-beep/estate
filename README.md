# CosyVoice Estate (房视界AI 声音克隆服务)

部署在 Zeabur (新加坡 2C 8G)，为房视界AI SaaS 提供零样本声音克隆 + TTS 接口。

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
url = "https://<你的 zeabur 域名>.zeabur.app"
# 1. 注册音色
requests.post(
    f"{url}/voice/clone",
    files={"audio": open("ref.wav", "rb")},
    data={"voice_id": "agent1"}
)
# 2. 合成
r = requests.post(
    f"{url}/tts",
    json={"text": "您好，欢迎参观这套三室两厅", "voice_id": "agent1"}
)
with open("out.wav", "wb") as f:
    f.write(r.content)
```

## 部署流程

1. 推送代码到 GitHub：`qianzhouxia-beep/estate`
2. Zeabur 创建服务 → 关联 GitHub 仓库 → 自动构建
3. 设置环境变量：
   - `ALLOWED_IPS=150.158.100.236`
   - `PORT=8000`
4. 等待构建完成（首次构建约 5-10 分钟）
5. 容器启动后会自动下载模型（约 5-10 分钟）
6. 访问 `https://<域名>.zeabur.app/health` 验证

## 资源评估

- 镜像大小：约 2.5GB（多阶段构建后）
- 启动时下载模型：约 300MB
- 运行时内存：约 3-4GB（2C 8G 容器可承载）
- 单条 TTS 推理：约 20-60 秒（10 秒口播音频）
