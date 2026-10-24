"""API tests with the speech model and Ollama replaced by fakes. Run: pytest"""

import json
import os

import pytest
from fastapi.testclient import TestClient

import main

# No `with` block, so the startup hook that loads Whisper does not run.
client = TestClient(main.app)

CREDIT = json.dumps({"commands": [{
    "action": "credit", "customer": "Ahmad", "item": "cheeni",
    "quantity": None, "unit": None, "amount": 500,
}]})


def fake_ollama(*answers):
    calls = []

    async def _call(text):
        calls.append(text)
        return answers[min(len(calls), len(answers)) - 1]

    return _call, calls


def test_parse_returns_normalized_commands(monkeypatch):
    fake, calls = fake_ollama(CREDIT)
    monkeypatch.setattr(main, "call_ollama", fake)

    response = client.post("/parse", json={"text": "Ahmad took 500 rupees of sugar on credit"})

    assert response.status_code == 200
    body = response.json()
    assert body["transcript"] == "Ahmad took 500 rupees of sugar on credit"
    assert body["commands"] == [{
        "action": "credit", "customer": "Ahmad", "item": "sugar",
        "quantity": None, "unit": None, "amount": 500.0,
    }]
    assert len(calls) == 1


def test_parse_retries_once_on_garbage(monkeypatch):
    fake, calls = fake_ollama("not json at all", CREDIT)
    monkeypatch.setattr(main, "call_ollama", fake)

    response = client.post("/parse", json={"text": "Ahmad udhaar"})

    assert response.status_code == 200
    assert len(calls) == 2


def test_parse_gives_502_after_two_bad_answers(monkeypatch):
    fake, calls = fake_ollama("nope", "still nope")
    monkeypatch.setattr(main, "call_ollama", fake)

    response = client.post("/parse", json={"text": "hello"})

    assert response.status_code == 502
    assert "could not be read" in response.json()["detail"]
    assert len(calls) == 2


def test_parse_rejects_empty_text():
    assert client.post("/parse", json={"text": ""}).status_code == 422


def test_voice_transcribes_then_parses_and_deletes_temp_file(monkeypatch):
    seen = {}

    def fake_transcribe(path):
        seen["path"] = path
        seen["existed"] = os.path.exists(path)
        return "احمد نے پانچ سو روپے کی چینی ادھار لی"

    fake, _ = fake_ollama(CREDIT)
    monkeypatch.setattr(main, "transcribe", fake_transcribe)
    monkeypatch.setattr(main, "call_ollama", fake)

    response = client.post("/voice", files={"audio": ("command.wav", b"RIFFfake", "audio/wav")})

    assert response.status_code == 200
    body = response.json()
    assert body["transcript"].startswith("احمد")
    assert body["commands"][0]["item"] == "sugar"
    assert seen["existed"] is True
    assert not os.path.exists(seen["path"])  # cleaned up


def test_voice_silence_returns_no_commands_without_calling_the_llm(monkeypatch):
    fake, calls = fake_ollama(CREDIT)
    monkeypatch.setattr(main, "transcribe", lambda path: "")
    monkeypatch.setattr(main, "call_ollama", fake)

    response = client.post("/voice", files={"audio": ("c.wav", b"RIFFfake", "audio/wav")})

    assert response.status_code == 200
    assert response.json() == {"transcript": "", "commands": []}
    assert calls == []


def test_voice_rejects_empty_upload():
    response = client.post("/voice", files={"audio": ("c.wav", b"", "audio/wav")})
    assert response.status_code == 400


def test_voice_rejects_oversized_upload(monkeypatch):
    monkeypatch.setattr(main, "MAX_AUDIO_BYTES", 10)
    response = client.post("/voice", files={"audio": ("c.wav", b"x" * 11, "audio/wav")})
    assert response.status_code == 413


def test_health_reports_ollama_down(monkeypatch):
    monkeypatch.setattr(main, "OLLAMA_URL", "http://127.0.0.1:9")  # nothing listens here

    body = client.get("/health").json()

    assert body["status"] == "ok"
    assert body["ollama"] is False
    assert "ollama serve" in body["hint"]
