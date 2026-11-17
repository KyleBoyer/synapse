#!/usr/bin/env python3
"""Checks the modality endpoints with the official SDKs, one section per milestone (added as milestones land).

Usage: python verify-modalities.py <host-url> <api-key> [--only a,b,c]
  e.g. .venv-sdk/bin/python scripts/verify-modalities.py http://127.0.0.1:19000 sk-local --only tts,embeddings
"""
import argparse
import sys

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("host")
ap.add_argument("key")
ap.add_argument("--only", default="", help="comma-separated section names; default runs all")
args = ap.parse_args()
HOST, KEY = args.host.rstrip("/"), args.key
ONLY = {s for s in args.only.split(",") if s}
failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  [{detail}]" if detail else ""))
    if not ok:
        failures.append(label)


def speech():
    import tempfile
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    tmp = tempfile.mkdtemp()
    sizes = {}
    for fmt in ("mp3", "wav"):
        path = f"{tmp}/fox.{fmt}"
        client.audio.speech.create(model="tts-1", voice="alloy", input="The quick brown fox.", response_format=fmt).write_to_file(path)
        sizes[fmt] = len(open(path, "rb").read())
        check(f"speech {fmt} size > 5 KB", sizes[fmt] > 5000, f"{sizes[fmt]} bytes")
    path = f"{tmp}/stream.mp3"
    with client.audio.speech.with_streaming_response.create(model="tts-1", voice="alloy", input="The quick brown fox.") as r:
        r.stream_to_file(path)
    check("speech streaming response", len(open(path, "rb").read()) > 5000)
    with open(f"{tmp}/fox.wav", "rb") as f:
        text = client.audio.transcriptions.create(model="parakeet-v3", file=f).text
    check("wav transcribes back to 'fox'", "fox" in text.lower(), text)


def embeddings():
    from openai import OpenAI
    from openai.types import CreateEmbeddingResponse

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    texts = ["What is the capital of France?", "Paris is the capital of France.", "Bananas are yellow."]
    # The SDK requests base64 by default and decodes it; this exercises that path.
    r = client.embeddings.create(model="text-embedding-3-small", input=texts)
    CreateEmbeddingResponse.model_validate(r.model_dump())
    v = [d.embedding for d in r.data]
    cos = lambda a, b: sum(x * y for x, y in zip(a, b))
    norm = max(abs(sum(x * x for x in e) ** 0.5 - 1) for e in v)
    check("embeddings schema, unit norm", len(v) == 3 and norm < 1e-2, f"model {r.model}, dim {len(v[0])}, max |norm-1| {norm:.4f}")
    check("embeddings rank Paris above bananas", cos(v[0], v[1]) > cos(v[0], v[2]) + 0.1,
          f"{cos(v[0], v[1]):.3f} vs {cos(v[0], v[2]):.3f}")
    r = client.embeddings.create(model="text-embedding-3-small", input="hello", dimensions=256, encoding_format="float")
    check("embeddings dimensions=256", len(r.data[0].embedding) == 256)


def rerank():
    import json
    import urllib.request

    body = {"query": "What is the capital of France?", "top_n": 2, "return_documents": True,
            "documents": ["Bananas are yellow.", "Paris is the capital of France.", "The sky is blue."]}
    req = urllib.request.Request(f"{HOST}/v1/rerank", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        r = json.load(resp)
    res = r.get("results", [])
    check("rerank puts Paris first, top_n respected", len(res) == 2 and res[0]["index"] == 1
          and res[0]["document"]["text"].startswith("Paris"), str([(x["index"], round(x["relevance_score"], 4)) for x in res]))


def diarize():
    from pathlib import Path
    from openai import OpenAI
    from openai.types.audio import TranscriptionDiarized

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    fixture = Path(__file__).resolve().parent.parent / "Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures/two-speakers.m4a"
    with open(fixture, "rb") as f:
        r = client.audio.transcriptions.create(model="gpt-4o-transcribe-diarize", file=f, response_format="diarized_json",
                                               chunking_strategy="auto")
    TranscriptionDiarized.model_validate(r.model_dump())
    speakers = [s.speaker for s in r.segments]
    check("diarized_json validates, two speakers alternate", len(set(speakers)) >= 2 and speakers[0] != speakers[-1],
          " ".join(speakers))


def video_input():
    import base64
    from pathlib import Path
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    fixture = Path(__file__).resolve().parent.parent / "Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures/zebra.mp4"
    url = "data:video/mp4;base64," + base64.b64encode(fixture.read_bytes()).decode()
    r = client.chat.completions.create(
        model="qwen3.5-0.8b", temperature=0, max_tokens=16,
        messages=[{"role": "user", "content": [
            {"type": "text", "text": "What animal is in this video? Answer with one word."},
            {"type": "video_url", "video_url": {"url": url}}]}])
    answer = r.choices[0].message.content or ""
    check("chat completion names the animal in a video", "zebra" in answer.lower(), answer.strip())
    try:
        client.chat.completions.create(model="qwen3.5-0.8b", messages=[{"role": "user", "content": [
            {"type": "video_url", "video_url": {"url": "file:///etc/hosts"}}]}])
        check("file:// video URL refused", False, "accepted")
    except Exception as e:  # openai.BadRequestError
        check("file:// video URL refused", getattr(e, "status_code", None) == 400, str(e)[:80])


def videos():
    """Run the server with SYNAPSE_MOCK_VIDEO=1 on Macs without the RAM for LTX-2.3."""
    import os, tempfile, time
    from openai import OpenAI
    from openai.types import Video

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    v = client.videos.create(model="sora-2", prompt="A red fox walking through snow", seconds="4", size="1280x720")
    check("create returns a queued video", v.status in ("queued", "in_progress") and v.id.startswith("video_"), v.status)
    for _ in range(600):
        v = client.videos.retrieve(v.id)
        if v.status in ("completed", "failed"):
            break
        time.sleep(1)
    Video.model_validate(v.model_dump())
    check("video completes", v.status == "completed" and v.progress == 100, f"{v.status} {v.progress} {v.error}")
    path = os.path.join(tempfile.mkdtemp(), "out.mp4")
    client.videos.download_content(v.id).write_to_file(path)
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        head = f.read(8)
    check("download_content is an MP4", size > 1000 and head[4:8] == b"ftyp", f"{size} bytes")
    check("list contains it", any(x.id == v.id for x in client.videos.list()))
    d = client.videos.delete(v.id)
    check("delete", d.deleted and d.id == v.id)


def sound():
    """Run the server with SYNAPSE_MOCK_SOUND=1 unless a Stable Audio 3 model is downloaded."""
    import json, urllib.request
    req = urllib.request.Request(f"{HOST}/v1/audio/generations", method="POST",
                                 data=json.dumps({"prompt": "a dog barking", "seconds": 3}).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    with urllib.request.urlopen(req, timeout=600) as r:
        body, ctype = r.read(), r.headers.get("Content-Type")
    check("audio/generations returns a WAV", ctype == "audio/wav" and body[:4] == b"RIFF" and len(body) > 100_000,
          f"{ctype}, {len(body)} bytes")


def omni():
    """Audio understanding through Gemma 3n (mlx-vlm backend): an OpenAI input_audio part."""
    import base64, subprocess, tempfile, os
    from pathlib import Path
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    fixture = Path(__file__).resolve().parent.parent / "Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures/en.m4a"
    wav = os.path.join(tempfile.mkdtemp(), "en.wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(fixture), wav], check=True)
    data = base64.b64encode(open(wav, "rb").read()).decode()
    r = client.chat.completions.create(
        model="gemma-3n-e2b", temperature=0, max_tokens=40,
        messages=[{"role": "user", "content": [
            {"type": "text", "text": "What does the speaker say? Answer with the exact words."},
            {"type": "input_audio", "input_audio": {"data": data, "format": "wav"}}]}])
    answer = r.choices[0].message.content or ""
    check("input_audio understood by gemma-3n-e2b", "fox" in answer.lower(), answer.strip()[:80])
    try:
        client.chat.completions.create(model="qwen3.5-0.8b", messages=[{"role": "user", "content": [
            {"type": "input_audio", "input_audio": {"data": data, "format": "wav"}}]}])
        check("audio refused for a model without audio input", False, "accepted")
    except Exception as e:
        check("audio refused for a model without audio input", getattr(e, "status_code", None) == 400, str(e)[:80])


def chat_audio():
    """Spoken replies on Chat Completions: a chat model plus TTS, and an omni model in its own voice."""
    import base64, io, wave
    from openai import OpenAI
    from openai.types.chat import ChatCompletion, ChatCompletionChunk

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    ask = [{"role": "system", "content": "Answer in one short sentence."},
           {"role": "user", "content": "What is the capital of France?"}]

    def heard(wav_bytes):
        return client.audio.transcriptions.create(model="whisper-1", file=("reply.wav", wav_bytes)).text

    for model in ["qwen3.5-0.8b", "lfm3-omni-2b"]:
        r = client.chat.completions.create(model=model, modalities=["text", "audio"], audio={"voice": "alloy", "format": "wav"},
                                           messages=ask, max_tokens=60)
        ChatCompletion.model_validate(r.model_dump())
        a = r.choices[0].message.audio
        wav = base64.b64decode(a.data)
        with wave.open(io.BytesIO(wav)) as w:
            seconds = w.getnframes() / w.getframerate()
        said = heard(wav)
        check(f"{model}: message.audio wav, transcript and speech say Paris",
              a.id.startswith("audio_") and 0.5 < seconds < 60 and "paris" in a.transcript.lower() and "paris" in said.lower(),
              f"{seconds:.1f}s; transcript {a.transcript!r}; heard {said!r}")

        stream = client.chat.completions.create(model=model, modalities=["text", "audio"], audio={"voice": "alloy", "format": "pcm16"},
                                                messages=ask, max_tokens=60, stream=True, stream_options={"include_usage": True})
        text, pcm, ids, expiry, usage = "", b"", set(), None, None
        for ch in stream:
            ChatCompletionChunk.model_validate(ch.model_dump())
            if ch.usage: usage = ch.usage
            for c in ch.choices:
                d = c.delta.audio
                if d is None: continue
                d = d if isinstance(d, dict) else d.model_dump()
                if d.get("id"): ids.add(d["id"])
                text += d.get("transcript") or ""
                if d.get("data"): pcm += base64.b64decode(d["data"])
                expiry = d.get("expires_at") or expiry
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(pcm)
        said = heard(buf.getvalue())
        check(f"{model}: streamed pcm16 deltas say Paris",
              len(ids) == 1 and expiry and len(pcm) > 24000 and "paris" in text.lower() and "paris" in said.lower() and usage,
              f"{len(pcm) / 48000:.1f}s; transcript {text.strip()!r}; heard {said!r}")
    try:
        client.chat.completions.create(model="qwen3.5-0.8b", modalities=["text", "audio"], audio={"voice": "alloy", "format": "mp3"},
                                       messages=ask, stream=True)
        check("streaming mp3 refused", False, "accepted")
    except Exception as e:
        check("streaming mp3 refused", getattr(e, "status_code", None) == 400, str(e)[:80])


# name -> function; milestones register their sections here.
SECTIONS = {"speech": speech, "embeddings": embeddings, "rerank": rerank, "diarize": diarize, "video-input": video_input, "videos": videos, "sound": sound, "omni": omni, "chat-audio": chat_audio}

unknown = ONLY - SECTIONS.keys()
if unknown:
    sys.exit(f"unknown section(s): {', '.join(sorted(unknown))}; known: {', '.join(SECTIONS) or 'none yet'}")
for name, run in SECTIONS.items():
    if not ONLY or name in ONLY:
        print(f"== {name}")
        run()

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
