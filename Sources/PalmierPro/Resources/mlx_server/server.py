#!/usr/bin/env python3
"""PalmierPro Local Inference Server — OpenAI-compatible API."""
import json, sys, os, io, base64, signal, threading, wave
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

MODELS_DIR = os.environ.get("PALMIER_MODELS_DIR",
    os.path.expanduser("~/Library/Application Support/PalmierPro/Models"))


# ---------------------------------------------------------------------------
# Model manager — lazy-loads on demand, caches in memory
# ---------------------------------------------------------------------------

class ModelManager:
    _instance = None
    _loaded = {}
    _lock = threading.Lock()

    @classmethod
    def instance(cls):
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def get(self, model_id, category):
        key = f"{category}:{model_id}"
        if key in self._loaded:
            return self._loaded[key]
        with self._lock:
            if key in self._loaded:
                return self._loaded[key]
            self._loaded[key] = self._load(model_id, category)
            return self._loaded[key]

    def _load(self, model_id, category):
        if category == "tts":
            return self._load_tts()
        if category == "music":
            return self._load_music()
        if category == "sfx":
            return self._load_sfx()
        if category == "upscale":
            return self._load_upscale(model_id)
        raise ValueError(f"Unknown category: {category}")

    # -- TTS: Kokoro-82M via mlx_audio ------------------------------------

    def _load_tts(self):
        try:
            from mlx_audio.tts import load_model
            model = load_model("mlx-community/Kokoro-82M")
            return {"type": "tts", "model": model}
        except ImportError:
            raise ImportError(
                "mlx-audio not installed. Run: pip install mlx-audio"
            )

    # -- Music: ACE-Step 1.5 ----------------------------------------------

    def _load_music(self):
        try:
            from ace_step.ace_step_pipeline import ACEStepPipeline
            import torch
            pipe = ACEStepPipeline(device="mps", dtype="float32")
            return {"type": "music", "pipeline": pipe}
        except ImportError:
            raise ImportError(
                "ace-step not installed. Run: pip install ace-step"
            )

    # -- SFX: TangoFlux ---------------------------------------------------

    def _load_sfx(self):
        try:
            from tangoflux import TangoFluxInference
            model = TangoFluxInference(name="declare-lab/TangoFlux")
            return {"type": "sfx", "model": model}
        except ImportError:
            raise ImportError(
                "tangoflux not installed. Run: pip install tangoflux"
            )

    # -- Upscale: PiperSR (2x) / Real-ESRGAN (4x) -------------------------

    def _load_upscale(self, model_id):
        if model_id == "pipersr-2x":
            return self._load_pipersr()
        if model_id == "realesrgan-4x":
            return self._load_realesrgan()
        raise ValueError(f"Unknown upscale model: {model_id}")

    def _load_pipersr(self):
        try:
            from pipersr import upscale as pipersr_upscale
            return {"type": "upscale", "mode": "2x", "fn": pipersr_upscale}
        except ImportError:
            raise ImportError(
                "pipersr not installed. Run: pip install pipersr"
            )

    def _load_realesrgan(self):
        try:
            import torch
            from realesrgan import RealESRGANer
            from basicsr.archs.rrdbnet_arch import RRDBNet
            import urllib.request

            model_url = (
                "https://github.com/xinntao/Real-ESRGAN/"
                "releases/download/v0.1.0/RealESRGAN_x4plus.pth"
            )
            cache_path = os.path.join(MODELS_DIR, "RealESRGAN_x4plus.pth")
            if not os.path.exists(cache_path):
                os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                urllib.request.urlretrieve(model_url, cache_path)

            model = RRDBNet(
                num_in_ch=3, num_out_ch=3, num_feat=64,
                num_block=23, num_grow_ch=32, scale=4,
            )
            upsampler = RealESRGANer(
                scale=4, model_path=cache_path, model=model,
                tile=256, half=False, device=torch.device("mps"),
            )
            return {"type": "upscale", "mode": "4x", "upsampler": upsampler}
        except ImportError:
            raise ImportError(
                "realesrgan not installed. Run: pip install realesrgan basicsr"
            )

    # -- Unload ------------------------------------------------------------

    def unload(self, model_id, category=None):
        with self._lock:
            if category:
                self._loaded.pop(f"{category}:{model_id}", None)
            else:
                keys = [k for k in self._loaded if k.endswith(f":{model_id}")]
                for k in keys:
                    del self._loaded[k]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _numpy_to_wav(numpy_array, sample_rate=44100):
    """Convert float32 numpy audio (any channels) to WAV bytes."""
    import numpy as np
    audio = np.clip(numpy_array, -1.0, 1.0)
    audio_int16 = (audio * 32767).astype(np.int16)
    if audio_int16.ndim == 1:
        audio_int16 = np.column_stack([audio_int16, audio_int16])
    elif audio_int16.ndim == 2 and audio_int16.shape[1] == 1:
        audio_int16 = np.column_stack([audio_int16[:, 0], audio_int16[:, 0]])
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_int16.tobytes())
    return buf.getvalue()


def _base64_to_pil(data_url):
    """Decode data:image/*;base64,... into a PIL Image."""
    from PIL import Image
    _, encoded = data_url.split(",", 1)
    return Image.open(io.BytesIO(base64.b64decode(encoded)))


def _pil_to_base64(pil_img, fmt="PNG"):
    """Encode PIL Image as base64 string."""
    buf = io.BytesIO()
    pil_img.save(buf, format=fmt)
    return base64.b64encode(buf.getvalue()).decode()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

manager = ModelManager.instance()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self._json_response(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self._list_models()
        else:
            self._json_response(404, {"error": "not found"})

    def do_POST(self):
        try:
            if self.path == "/v1/audio/speech":
                self._handle_tts()
            elif self.path == "/v1/images/generations":
                self._json_response(
                    501, {"error": "image generation not implemented"}
                )
            elif self.path == "/v1/audio/generations":
                self._handle_music()
            elif self.path == "/v1/audio/sound-effects":
                self._handle_sfx()
            elif self.path == "/v1/videos":
                self._handle_video()
            elif self.path == "/v1/images/upscale":
                self._handle_upscale()
            elif self.path == "/v1/unload":
                self._handle_unload()
            else:
                self._json_response(404, {"error": "not found"})
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    # -- TTS ---------------------------------------------------------------

    def _handle_tts(self):
        body = self._read_body()
        try:
            model_info = manager.get(body.get("model", "kokoro-82m"), "tts")
        except ImportError as e:
            return self._json_response(501, {"error": str(e)})

        try:
            from mlx_audio.tts import generate
            audio = generate(
                model_info["model"], text=body.get("input", "")
            )
            import numpy as np
            audio = np.clip(audio, -1.0, 1.0)
            audio_bytes = (audio * 32767).astype(np.int16).tobytes()
            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm")
            self.send_header("Content-Length", str(len(audio_bytes)))
            self.end_headers()
            self.wfile.write(audio_bytes)
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    # -- Music -------------------------------------------------------------

    def _handle_music(self):
        body = self._read_body()
        try:
            model_info = manager.get(
                body.get("model", "ace-step-1.5"), "music"
            )
        except ImportError as e:
            return self._json_response(501, {"error": str(e)})

        try:
            prompt = body.get("prompt", "")
            duration = body.get("duration_seconds", 15)
            steps = body.get("steps", 8)
            pipe = model_info["pipeline"]
            audio = pipe(prompt, duration=duration, steps=steps)
            if hasattr(audio, "numpy"):
                audio_np = audio.numpy()
            else:
                audio_np = audio
            wav_bytes = _numpy_to_wav(audio_np)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav_bytes)))
            self.end_headers()
            self.wfile.write(wav_bytes)
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    # -- SFX ---------------------------------------------------------------

    def _handle_sfx(self):
        body = self._read_body()
        try:
            model_info = manager.get(
                body.get("model", "tangoflux"), "sfx"
            )
        except ImportError as e:
            return self._json_response(501, {"error": str(e)})

        try:
            prompt = body.get("prompt", "")
            duration = body.get("duration_seconds", 10)
            steps = body.get("steps", 50)
            sfx_model = model_info["model"]
            audio = sfx_model.generate(prompt, steps=steps, duration=duration)
            if hasattr(audio, "numpy"):
                audio_np = audio.numpy()
            else:
                audio_np = audio
            wav_bytes = _numpy_to_wav(audio_np)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav_bytes)))
            self.end_headers()
            self.wfile.write(wav_bytes)
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    # -- Video (stub) ------------------------------------------------------

    def _handle_video(self):
        self._json_response(
            501,
            {"error": "video generation not implemented. "
                       "LTX-Video integration pending."},
        )

    # -- Upscale -----------------------------------------------------------

    def _handle_upscale(self):
        body = self._read_body()
        model_id = body.get("model", "pipersr-2x")
        try:
            model_info = manager.get(model_id, "upscale")
        except ImportError as e:
            return self._json_response(501, {"error": str(e)})

        try:
            import numpy as np
            from PIL import Image as PILImage

            image_url = body.get("image_url", "")
            pil_img = _base64_to_pil(image_url)

            if model_info["mode"] == "2x":
                result = model_info["fn"](pil_img)
                b64 = _pil_to_base64(result)
            else:
                img_np = np.array(pil_img.convert("RGB"))
                output, _ = model_info["upsampler"].enhance(
                    img_np, outscale=4
                )
                if isinstance(output, PILImage.Image):
                    b64 = _pil_to_base64(output)
                else:
                    result_img = PILImage.fromarray(
                        output[:, :, ::-1]  # BGR->RGB
                    )
                    b64 = _pil_to_base64(result_img)

            self._json_response(200, {
                "data": [{"b64_json": b64, "url": None}],
            })
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    # -- Unload ------------------------------------------------------------

    def _handle_unload(self):
        body = self._read_body()
        try:
            manager.unload(body.get("model", ""))
            self._json_response(200, {"status": "unloaded"})
        except Exception as e:
            self._json_response(500, {"error": str(e)})

    # -- Models list -------------------------------------------------------

    def _list_models(self):
        models = []
        models_path = Path(MODELS_DIR)
        if models_path.exists():
            for p in models_path.iterdir():
                if p.is_dir() and (p / "config.json").exists():
                    try:
                        config = json.loads(
                            (p / "config.json").read_text()
                        )
                    except (json.JSONDecodeError, UnicodeDecodeError,
                            OSError):
                        continue
                    models.append({
                        "id": p.name,
                        "object": "model",
                        "owned_by": "local",
                    })
        self._json_response(200, {"data": models})

    # -- Request helpers ---------------------------------------------------

    def _read_body(self):
        try:
            length = min(
                int(self.headers.get("Content-Length", 0)),
                16 * 1024 * 1024,
            )
            if length == 0:
                return {}
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError, OSError):
            return {}

    def _json_response(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"MLX server running on http://127.0.0.1:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
