"""BayanAI AI service.

    audio  --faster-whisper-->  text  --Ollama (open LLM)-->  shop commands

Both models are open source and run on this machine; no audio or shop data is
sent to a paid API. Start it with:

    uvicorn main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import logging
import os
import tempfile
import threading
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from parsing import SYSTEM_PROMPT, Command, parse_llm_output

log = logging.getLogger("bayanai")
logging.basicConfig(level=logging.INFO)

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434").rstrip("/")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:7b")
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")
# "ur" for Urdu / Roman Urdu speech, "en" for English, "auto" to let Whisper
# guess (it can guess wrong on short clips).
WHISPER_LANGUAGE = os.getenv("WHISPER_LANGUAGE", "ur")
WHISPER_DEVICE = os.getenv("WHISPER_DEVICE", "auto")
WHISPER_COMPUTE = os.getenv("WHISPER_COMPUTE", "int8")
MAX_AUDIO_BYTES = 10 * 1024 * 1024

# A short Urdu sentence in shop vocabulary nudges Whisper toward these words.
URDU_HINT = "احمد نے پانچ سو روپے کی چینی ادھار پر لی۔ بلال نے دو سو روپے واپس دیے۔"

_whisper = None
_load_lock = threading.Lock()
_infer_lock = threading.Lock()


def get_whisper():
    """Loads the speech model on first use (and once at startup)."""
    global _whisper
    with _load_lock:
        if _whisper is None:
            from faster_whisper import WhisperModel

            log.info("Loading Whisper model '%s' ...", WHISPER_MODEL)
            _whisper = WhisperModel(
                WHISPER_MODEL,
                device=WHISPER_DEVICE,
                compute_type=WHISPER_COMPUTE,
            )
            log.info("Whisper ready.")
        return _whisper


def transcribe(path: str) -> str:
    model = get_whisper()
    language = None if WHISPER_LANGUAGE.lower() in ("", "auto") else WHISPER_LANGUAGE
    with _infer_lock:
        # `segments` is lazy: the audio is only decoded while we iterate it.
        segments, _info = model.transcribe(
            path,
            language=language,
            task="transcribe",
            beam_size=5,
            vad_filter=True,
            initial_prompt=URDU_HINT if language == "ur" else None,
        )
        return " ".join(segment.text.strip() for segment in segments).strip()


async def call_ollama(text: str) -> str:
    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "format": "json",
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text},
        ],
    }
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(120.0, connect=5.0)
        ) as client:
            response = await client.post(f"{OLLAMA_URL}/api/chat", json=payload)
    except httpx.TimeoutException:
        raise HTTPException(
            504, "The language model took too long. Try a smaller model."
        )
    except httpx.TransportError:
        raise HTTPException(
            502,
            f"Cannot reach Ollama at {OLLAMA_URL}. Start it with: ollama serve",
        )

    if response.status_code == 404:
        raise HTTPException(
            502,
            f"Model '{OLLAMA_MODEL}' is not installed. Run: ollama pull {OLLAMA_MODEL}",
        )
    if response.status_code != 200:
        raise HTTPException(
            502, f"Ollama error {response.status_code}: {response.text[:200]}"
        )
    try:
        return response.json()["message"]["content"]
    except (KeyError, ValueError):
        raise HTTPException(502, "Ollama sent an answer in an unexpected format.")


async def extract_commands(text: str) -> list[Command]:
    """Asks the model, validates the answer, and retries once if it is unusable."""
    last_error = ""
    for attempt in (1, 2):
        raw = await call_ollama(text)
        try:
            return parse_llm_output(raw)
        except ValueError as exc:
            last_error = str(exc)
            log.warning("Attempt %d: unusable model output (%s): %.200s", attempt, exc, raw)
    raise HTTPException(
        502,
        f"The language model's answer could not be read ({last_error}). "
        "Try again, or use a larger model.",
    )


class ParseRequest(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


class ParseResponse(BaseModel):
    transcript: str
    commands: list[Command]


@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        await run_in_threadpool(get_whisper)
    except Exception as exc:  # keep /parse and /health working
        log.warning("Whisper not loaded (%s). /voice will fail until this is fixed.", exc)
    yield


app = FastAPI(title="BayanAI AI service", lifespan=lifespan)


@app.get("/health")
async def health():
    reachable = False
    installed = False
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            response = await client.get(f"{OLLAMA_URL}/api/tags")
        if response.status_code == 200:
            reachable = True
            names = {m.get("name") for m in response.json().get("models", [])}
            installed = OLLAMA_MODEL in names or f"{OLLAMA_MODEL}:latest" in names
    except (httpx.HTTPError, ValueError):
        pass

    hint = ""
    if not reachable:
        hint = "Ollama is not running. Start it with: ollama serve"
    elif not installed:
        hint = f"Model not installed. Run: ollama pull {OLLAMA_MODEL}"

    return {
        "status": "ok",
        "ollama": reachable and installed,
        "hint": hint,
        "ollama_model": OLLAMA_MODEL,
        "whisper_model": WHISPER_MODEL,
        "whisper_loaded": _whisper is not None,
    }


@app.post("/parse", response_model=ParseResponse)
async def parse_text(body: ParseRequest):
    """Typed (or corrected) text -> commands. No audio involved."""
    text = body.text.strip()
    if not text:
        raise HTTPException(422, "Text is empty.")
    return ParseResponse(transcript=text, commands=await extract_commands(text))


@app.post("/voice", response_model=ParseResponse)
async def voice(audio: UploadFile = File(...)):
    """Recording -> transcript -> commands."""
    data = await audio.read()
    if not data:
        raise HTTPException(400, "The recording is empty.")
    if len(data) > MAX_AUDIO_BYTES:
        raise HTTPException(413, "The recording is too long (limit 10 MB).")

    suffix = Path(audio.filename or "").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    try:
        try:
            transcript = await run_in_threadpool(transcribe, path)
        except ImportError:
            raise HTTPException(
                500, "faster-whisper is not installed. Run: pip install -r requirements.txt"
            )
        except Exception as exc:
            log.exception("Transcription failed")
            raise HTTPException(500, f"Could not transcribe the audio: {exc}")
    finally:
        os.unlink(path)

    log.info("Heard: %s", transcript)
    if not transcript:
        return ParseResponse(transcript="", commands=[])
    return ParseResponse(transcript=transcript, commands=await extract_commands(transcript))
