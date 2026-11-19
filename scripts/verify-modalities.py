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
def lmstudio():
    """LM Studio's /api/v1/chat: named stream events (load and prompt progress, message deltas, chat.end with stats)
    and a second turn through previous_response_id. LM Studio's SDK speaks websockets, so this is raw HTTP."""
    import json, urllib.request

    def post(body):
        req = urllib.request.Request(f"{HOST}/api/v1/chat", json.dumps(body).encode(),
                                     {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
        return urllib.request.urlopen(req, timeout=600)

    events, name = [], None
    for raw in post({"model": "qwen3.5-0.8b", "input": "What is the capital of France? One word.", "stream": True, "temperature": 0}):
        line = raw.decode().rstrip("\n")
        if line.startswith("event: "):
            name = line[7:]
        elif line.startswith("data: "):
            events.append((name, json.loads(line[6:])))
    check("lmstudio: every event's data carries its name as type", all(n == d.get("type") for n, d in events))
    events = [d for _, d in events]
    types = [e["type"] for e in events]
    check("lmstudio: stream starts with chat.start and ends with chat.end", types[:1] == ["chat.start"] and types[-1:] == ["chat.end"], str(types))
    check("lmstudio: prompt processing brackets the message",
          "prompt_processing.start" in types and types.index("prompt_processing.end") < types.index("message.start"), str(types))
    if "model_load.start" in types:
        check("lmstudio: model_load.end reports the load time", any(e["type"] == "model_load.end" and e.get("load_time_seconds", 0) > 0 for e in events))
    text = "".join(e["content"] for e in events if e["type"] == "message.delta")
    check("lmstudio: message deltas answer", "paris" in text.lower(), text)
    result = events[-1]["result"]
    check("lmstudio: chat.end result has output, stats and response_id",
          result["output"][-1] == {"type": "message", "content": text} and {"input_tokens", "total_output_tokens", "tokens_per_second",
                                                                             "time_to_first_token_seconds"} <= result["stats"].keys()
          and result.get("response_id", "").startswith("resp_"), json.dumps(result)[:200])
    follow = json.load(post({"model": "qwen3.5-0.8b", "input": "And of Italy? One word.", "previous_response_id": result["response_id"], "temperature": 0}))
    answer = follow["output"][-1]["content"]
    check("lmstudio: previous_response_id continues the conversation", "rome" in answer.lower() and follow["stats"]["input_tokens"] > result["stats"]["input_tokens"], answer)


def models():
    """Model listing and retrieval through both official SDKs (Anthropic with paging), and LM Studio's list."""
    import json, urllib.request
    from openai import OpenAI
    from anthropic import Anthropic

    oai = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    ids = [m.id for m in oai.models.list()]
    check("models: OpenAI list", "qwen3.5-0.8b" in ids, f"{len(ids)} models")
    m = oai.models.retrieve("qwen3.5-0.8b")
    check("models: OpenAI retrieve", m.id == "qwen3.5-0.8b" and m.object == "model" and m.created > 0, str(m)[:120])
    slashed = [i for i in ids if "/" in i]
    if slashed:
        check("models: OpenAI retrieve an org/name id", oai.models.retrieve(slashed[0]).id == slashed[0], slashed[0])

    ant = Anthropic(base_url=HOST, api_key=KEY)
    paged = [m.id for m in ant.models.list(limit=2)]   # the SDK follows has_more / after_id
    check("models: Anthropic list pages through every model", paged == ids, f"{len(paged)} via limit=2")
    info = ant.models.retrieve("qwen3.5-0.8b")
    check("models: Anthropic retrieve with capabilities", info.type == "model" and info.display_name and info.capabilities is not None
          and info.capabilities.image_input.supported, str(info)[:160])
    if slashed:
        check("models: Anthropic retrieve an org/name id", ant.models.retrieve(slashed[0]).id == slashed[0], slashed[0])

    req = urllib.request.Request(f"{HOST}/api/v1/models", headers={"Authorization": f"Bearer {KEY}"})
    lms = json.load(urllib.request.urlopen(req))["models"]
    check("models: LM Studio list has chat and embedding models only", lms and all(x["type"] in ("llm", "embedding") for x in lms),
          ", ".join(f'{x["key"]}:{x["format"]}' for x in lms))


def voices():
    """Custom voices through the official SDK: consent, clone from a sample, speak in that voice, hear it back, delete."""
    import os, subprocess, tempfile
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    tmp = tempfile.mkdtemp()
    def say(voice, text, name):
        out = os.path.join(tmp, name + ".aiff")
        subprocess.run(["say", "-v", voice, "-o", out, text], check=True)
        wav = os.path.join(tmp, name + ".wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", out, wav], check=True)
        return wav

    consent_wav = say("Daniel", "I agree to have my voice used to create a synthetic voice.", "consent")
    sample_wav = say("Daniel", "Good evening. I have been walking along the coast all afternoon, and the weather turned out "
                     "far better than the forecast suggested.", "sample")
    consent = client.audio.voice_consents.create(name="Daniel", language="en-GB", recording=open(consent_wav, "rb"))
    check("voices: consent created", consent.id and consent.object == "audio.voice_consent", consent.id)
    voice = client.audio.voices.create(name="Daniel", audio_sample=open(sample_wav, "rb"), consent=consent.id)
    check("voices: voice cloned", voice.id.startswith("voice_") and voice.object == "audio.voice", voice.id)
    audio = client.audio.speech.create(model="tts-1", voice={"id": voice.id}, input="The quick brown fox jumps over the lazy dog.",
                                       response_format="wav")
    data = audio.read()
    check("voices: speech in the cloned voice", len(data) > 20000, f"{len(data)} bytes")
    heard = client.audio.transcriptions.create(model="whisper-1", file=("clone.wav", data)).text
    check("voices: the cloned speech says the text", "fox" in heard.lower(), heard)
    deleted = client.audio.voices.delete(voice.id)
    check("voices: voice deleted", deleted.deleted and deleted.object == "audio.voice.deleted")
    client.audio.voice_consents.delete(consent.id)
    ids = [c.id for c in client.audio.voice_consents.list()]
    check("voices: consent deleted", consent.id not in ids)


def image_embeddings():
    """Images and text in one space through the official SDK (it passes Jina-style {"image"} items through as given)."""
    import base64, os
    import numpy as np
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    fx = os.path.join(os.path.dirname(__file__), "..", "Packages", "SynapseCore", "Tests", "SynapseCoreTests", "Fixtures")
    def data_url(name, mime):
        return f"data:{mime};base64," + base64.b64encode(open(os.path.join(fx, name), "rb").read()).decode()
    inputs = [{"image": data_url("zebra.jpg", "image/jpeg")}, {"image": data_url("penguin.png", "image/png")}, "a zebra", "a penguin"]
    for model in ["qwen3-vl-embedding-2b", "siglip2-so400m"]:
        r = client.embeddings.create(model=model, input=inputs)   # base64 encoding, the SDK default
        v = np.array([d.embedding for d in r.data])
        sims = v[:2] @ v[2:].T
        check(f"image-embeddings: {model} matches each image to its caption", sims[0, 0] > sims[0, 1] and sims[1, 1] > sims[1, 0],
              f"zebra {sims[0].round(2).tolist()}, penguin {sims[1].round(2).tolist()}")
    r = client.embeddings.create(model="text-embedding-3-small", input=[{"image": data_url("zebra.jpg", "image/jpeg")}])
    check("image-embeddings: an image picks an image model by default", r.model in ("qwen3-vl-embedding-2b", "siglip2-so400m"), r.model)
    both = client.embeddings.create(model="qwen3-vl-embedding-2b", input=[{"image": data_url("zebra.jpg", "image/jpeg"), "text": "a zebra"}])
    check("image-embeddings: an image and its text as one input", len(both.data) == 1 and len(both.data[0].embedding) == 2048)
    check("image-embeddings: usage counts the prompt tokens", both.usage.prompt_tokens > 0, f"{both.usage}")
    r = client.embeddings.create(model="text-embedding-3-small", input=[{"video": data_url("zebra.mp4", "video/mp4")}, "a zebra", "a penguin"])
    v = np.array([d.embedding for d in r.data])
    check("image-embeddings: a video picks Qwen3-VL and lands nearest its caption", r.model == "qwen3-vl-embedding-2b" and v[0] @ v[1] > v[0] @ v[2],
          f"{r.model}, zebra {v[0] @ v[1]:.2f}, penguin {v[0] @ v[2]:.2f}")


def audio_edit():
    """Noise removal and separation (needs deepfilternet-3 and sam-audio-small, plus a transcription model)."""
    import base64, io, json, os, subprocess, tempfile, urllib.error, urllib.request, wave
    import numpy as np
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    tmp = tempfile.mkdtemp()
    aiff = os.path.join(tmp, "say.wav")
    subprocess.run(["say", "-v", "Samantha", "-o", aiff, "--data-format=LEI16@48000",
                    "The quick brown fox jumps over the lazy dog by the river."], check=True)
    with wave.open(aiff) as w:
        voice = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
    voice = np.concatenate([np.zeros(48000, np.float32), voice])
    def wav(x):
        b = io.BytesIO()
        with wave.open(b, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
            w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
        return b.getvalue()
    def heard(data):
        return client.audio.transcriptions.create(model="whisper-1", file=("a.wav", data)).text.lower()
    class Reply:
        def __init__(self, status, ctype, content):
            self.status_code, self.headers, self.content = status, {"content-type": ctype}, content
            self.text = content.decode(errors="replace")
        def json(self):
            return json.loads(self.content)
    def post(path, data, **fields):
        parts = [f'--XyZ\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
        parts.append(b'--XyZ\r\nContent-Disposition: form-data; name="file"; filename="in.wav"\r\nContent-Type: audio/wav\r\n\r\n' + data + b"\r\n--XyZ--\r\n")
        req = urllib.request.Request(f"{HOST}/v1/audio/{path}", data=b"".join(parts), method="POST",
                                     headers={"Authorization": f"Bearer {KEY}", "Content-Type": "multipart/form-data; boundary=XyZ"})
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                return Reply(r.status, r.headers.get("Content-Type"), r.read())
        except urllib.error.HTTPError as e:
            return Reply(e.code, e.headers.get("Content-Type"), e.read())

    noisy = wav(voice + np.random.default_rng(0).uniform(-0.08, 0.08, voice.size).astype(np.float32))
    r = post("enhance", noisy)
    ok = r.status_code == 200 and r.content[:4] == b"RIFF"
    check("audio-edit: enhance returns a WAV", ok, f"{r.status_code} {r.headers.get('content-type')}")
    if ok:
        with wave.open(io.BytesIO(r.content)) as w:
            out = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
        lead_in, lead_out = np.sqrt(np.mean(voice[:38000] ** 2 + 0.08 ** 2 / 3)), np.sqrt(np.mean(out[:38000] ** 2))
        text = heard(r.content)
        check("audio-edit: enhance removes the noise and keeps the words", lead_out < lead_in / 4 and "fox" in text,
              f"lead-in rms {lead_in:.4f} -> {lead_out:.4f}; {text!r}")

    mix = wav(voice + 0.3 * np.sin(2 * np.pi * 220 * np.arange(voice.size) / 48000).astype(np.float32))
    r = post("separate", mix, prompt="speech")
    body = r.json() if r.status_code == 200 else {}
    names = [t["name"] for t in body.get("tracks", [])]
    check("audio-edit: separate with a prompt gives target and residual", names == ["residual", "target"], f"{r.status_code} {body.get('model')} {names or r.text[:200]}")
    if "target" in names:
        text = heard(base64.b64decode(body["tracks"][names.index("target")]["audio"]))
        check("audio-edit: the target track is the speech", "fox" in text, repr(text))

    # Voice conversion: the recording above, re-spoken in a voice cloned through the SDK (needs chatterbox-turbo).
    ref = os.path.join(tmp, "daniel.wav")
    subprocess.run(["say", "-v", "Daniel", "-o", ref, "--data-format=LEI16@24000", "Good evening. I have been walking along the coast "
                    "all afternoon, and the weather turned out far better than the forecast suggested."], check=True)
    v = client.audio.voices.create(name="Daniel", audio_sample=open(ref, "rb"), consent="none")
    try:
        r = post("convert", wav(voice), voice=v.id, model="chatterbox-turbo")
        text = heard(r.content) if r.status_code == 200 else r.text[:200]
        check("audio-edit: convert re-speaks the recording in the cloned voice", r.status_code == 200 and r.content[:4] == b"RIFF" and "fox" in text.lower(),
              f"{r.status_code} {text!r}")
    finally:
        urllib.request.urlopen(urllib.request.Request(f"{HOST}/v1/audio/voices/{v.id}", method="DELETE",
                                                      headers={"Authorization": f"Bearer {KEY}"}), timeout=30).read()


def tools():
    """Function tools on every chat route and input/output type, with the official SDK: text, image, video and audio in,
    spoken replies, Responses, and a GGUF model."""
    import base64, json, os, subprocess, tempfile
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    fx = os.path.join(os.path.dirname(__file__), "..", "Packages", "SynapseCore", "Tests", "SynapseCoreTests", "Fixtures")
    def b64(name):
        return base64.b64encode(open(os.path.join(fx, name), "rb").read()).decode()
    weather = {"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
               "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
    record = {"type": "function", "function": {"name": "record_animal", "description": "Record the animal seen in a picture or video.",
              "parameters": {"type": "object", "properties": {"animal": {"type": "string"}}, "required": ["animal"]}}}
    note = {"type": "function", "function": {"name": "save_note", "description": "Save a note with what the speaker said.",
            "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}}
    result = json.dumps({"city": "Paris", "temperature_c": 18, "sky": "light rain"})
    ask = [{"role": "user", "content": "What's the weather like in Paris right now?"}]

    # Chat Completions: a call, the result back, a streamed call.
    r = client.chat.completions.create(model="qwen3.5-2b", messages=ask, tools=[weather], temperature=0)
    m = r.choices[0].message
    call = (m.tool_calls or [None])[0]
    check("tools: chat completions returns a tool call", call is not None and call.function.name == "get_weather"
          and "paris" in call.function.arguments.lower() and r.choices[0].finish_reason == "tool_calls", f"{m}")
    if call:
        r2 = client.chat.completions.create(model="qwen3.5-2b", tools=[weather], temperature=0, messages=ask + [
            {"role": "assistant", "content": None, "tool_calls": [{"id": call.id, "type": "function",
             "function": {"name": call.function.name, "arguments": call.function.arguments}}]},
            {"role": "tool", "tool_call_id": call.id, "content": result}])
        answer = r2.choices[0].message.content or ""
        check("tools: chat completions answers from the tool result", "18" in answer or "rain" in answer.lower(), answer)
    names, args, finish = "", "", None
    for chunk in client.chat.completions.create(model="qwen3.5-2b", messages=ask, tools=[weather], temperature=0, stream=True):
        for c in chunk.choices:
            for tc in c.delta.tool_calls or []:
                names += tc.function.name or ""; args += tc.function.arguments or ""
            finish = c.finish_reason or finish
    check("tools: streamed chat completions tool call", names == "get_weather" and "paris" in args.lower() and finish == "tool_calls",
          f"{names} {args} {finish}")

    # Responses: a function_call item, the output back, a streamed call.
    rtool = {"type": "function", "name": "get_weather", "description": "Current weather for a city.", "parameters": weather["function"]["parameters"]}
    resp = client.responses.create(model="qwen3.5-2b", input="What's the weather like in Paris right now?", tools=[rtool], temperature=0)
    fc = next((o for o in resp.output if o.type == "function_call"), None)
    check("tools: responses returns a function_call item", fc is not None and fc.name == "get_weather" and "paris" in fc.arguments.lower(),
          f"{[o.type for o in resp.output]}")
    if fc:
        resp2 = client.responses.create(model="qwen3.5-2b", tools=[rtool], temperature=0, input=[
            {"role": "user", "content": "What's the weather like in Paris right now?"},
            {"type": "function_call", "call_id": fc.call_id, "name": fc.name, "arguments": fc.arguments},
            {"type": "function_call_output", "call_id": fc.call_id, "output": result}])
        check("tools: responses answers from the function output", "18" in resp2.output_text or "rain" in resp2.output_text.lower(), resp2.output_text)
    done = None
    with client.responses.stream(model="qwen3.5-2b", input="What's the weather like in Paris right now?", tools=[rtool], temperature=0) as st:
        for ev in st:
            if ev.type == "response.function_call_arguments.done":
                done = ev
        final = st.get_final_response()
    check("tools: streamed responses function call", done is not None and "paris" in done.arguments.lower()
          and any(o.type == "function_call" for o in final.output), f"{done}")

    # Image and video in: the model looks, then calls a tool with what it saw.
    look = "Identify the animal, then record it with record_animal."
    r = client.chat.completions.create(model="qwen3.5-2b", tools=[record], temperature=0, messages=[{"role": "user", "content": [
        {"type": "text", "text": look}, {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64("zebra.jpg")}}]}])
    call = (r.choices[0].message.tool_calls or [None])[0]
    check("tools: image in, tool call with what it saw", call is not None and "zebra" in call.function.arguments.lower(), f"{r.choices[0].message}")
    r = client.chat.completions.create(model="qwen3.5-2b", tools=[record], temperature=0, messages=[{"role": "user", "content": [
        {"type": "text", "text": look}, {"type": "video_url", "video_url": {"url": "data:video/mp4;base64," + b64("zebra.mp4")}}]}])
    call = (r.choices[0].message.tool_calls or [None])[0]
    check("tools: video in, tool call with what it saw", call is not None and "zebra" in call.function.arguments.lower(), f"{r.choices[0].message}")

    # Audio in (an mlx-vlm omni model): the model hears, then calls a tool with what it heard.
    tmp = tempfile.mkdtemp()
    wav = os.path.join(tmp, "en.wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", os.path.join(fx, "en.m4a"), wav], check=True)
    audio_b64 = base64.b64encode(open(wav, "rb").read()).decode()
    for model in ["gemma-4-e2b", "lfm3-omni-2b"]:
        r = client.chat.completions.create(model=model, tools=[note], temperature=0, messages=[{"role": "user", "content": [
            {"type": "text", "text": "Save what the speaker says with save_note."},
            {"type": "input_audio", "input_audio": {"data": audio_b64, "format": "wav"}}]}])
        call = (r.choices[0].message.tool_calls or [None])[0]
        check(f"tools: audio in ({model}), tool call with what it heard", call is not None and "fox" in call.function.arguments.lower(),
              f"{r.choices[0].message}")

    # Spoken replies: a tool call instead of audio, from TTS and from a model's own voice.
    for model in ["qwen3.5-2b", "lfm3-omni-2b"]:
        r = client.chat.completions.create(model=model, modalities=["text", "audio"], audio={"voice": "alloy", "format": "wav"},
                                           messages=ask, tools=[weather], temperature=0)
        m = r.choices[0].message
        call = (m.tool_calls or [None])[0]
        check(f"tools: spoken reply ({model}) returns a tool call", call is not None and call.function.name == "get_weather"
              and r.choices[0].finish_reason == "tool_calls", f"{m}")

    # A GGUF model through llama.cpp (added from Hugging Face in the app).
    gguf = "bartowski/Llama-3.2-1B-Instruct-GGUF"
    if gguf in [m.id for m in client.models.list()]:
        r = client.chat.completions.create(model=gguf, tools=[weather], temperature=0,
                                           messages=[{"role": "user", "content": "Call get_weather for Paris."}])
        call = (r.choices[0].message.tool_calls or [None])[0]
        check("tools: GGUF (llama.cpp) tool call", call is not None and call.function.name == "get_weather"
              and "paris" in call.function.arguments.lower(), f"{r.choices[0].message}")


def image_tools():
    """Cut-outs (macOS Vision, nothing to download) and depth maps (needs depth-anything-v2-small)."""
    import base64, io, json, os, urllib.error, urllib.request
    from PIL import Image

    zebra = open(os.path.join(os.path.dirname(__file__), "..", "Packages", "SynapseCore", "Tests", "SynapseCoreTests", "Fixtures", "zebra.jpg"), "rb").read()
    def post(path, **fields):
        parts = [f'--XyZ\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
        parts.append(b'--XyZ\r\nContent-Disposition: form-data; name="image"; filename="zebra.jpg"\r\nContent-Type: image/jpeg\r\n\r\n' + zebra + b"\r\n--XyZ--\r\n")
        req = urllib.request.Request(f"{HOST}/v1/images/{path}", data=b"".join(parts), method="POST",
                                     headers={"Authorization": f"Bearer {KEY}", "Content-Type": "multipart/form-data; boundary=XyZ"})
        with urllib.request.urlopen(req, timeout=300) as r:
            body = json.loads(r.read())
        return body, Image.open(io.BytesIO(base64.b64decode(body["data"][0]["b64_json"])))
    body, cut = post("cutout")
    alpha = cut.getchannel("A") if cut.mode == "RGBA" else None
    covered = sum(alpha.histogram()[128:]) / (cut.width * cut.height) if alpha else 0
    check("image-tools: cutout is a transparent PNG with the subject kept", body["background"] == "transparent" and 0.1 < covered < 0.9,
          f"{cut.mode} {cut.size}, subject covers {covered:.0%}")
    _, mask = post("cutout", output="mask")
    check("image-tools: mask is grayscale at the input size", mask.mode == "L" and mask.size == (448, 448), f"{mask.mode} {mask.size}")
    _, depth = post("depth")
    top_right, middle = depth.crop((400, 0, 448, 48)), depth.crop((150, 200, 250, 300))
    near, far = sum(middle.getdata()) / (100 * 100), sum(top_right.getdata()) / (48 * 48)
    check("image-tools: depth puts the zebra in front of the sky", depth.mode == "L" and near > far + 50, f"zebra {near:.0f}, sky {far:.0f}")
    _, big = post("upscale")
    check("image-tools: upscale makes it four times larger", big.size == (1792, 1792), f"{big.size}")


def video_transform():
    """Every frame through an image tool (mask needs nothing; depth and upscale need their models). Output is checked
    with macOS's own avmetareadwrite-free probe: the MP4 header and, via ffprobe when installed, size and frame count."""
    import json, os, shutil, subprocess, tempfile, urllib.request

    clip = open(os.path.join(os.path.dirname(__file__), "..", "Packages", "SynapseCore", "Tests", "SynapseCoreTests", "Fixtures", "zebra.mp4"), "rb").read()
    ffprobe = shutil.which("ffprobe")
    for op, size in [("mask", "320x320"), ("depth", "320x320"), ("upscale", "1280x1280")]:
        body = (f'--XyZ\r\nContent-Disposition: form-data; name="operation"\r\n\r\n{op}\r\n'.encode()
                + b'--XyZ\r\nContent-Disposition: form-data; name="file"; filename="zebra.mp4"\r\nContent-Type: video/mp4\r\n\r\n' + clip + b"\r\n--XyZ--\r\n")
        req = urllib.request.Request(f"{HOST}/v1/videos/transform", data=body, method="POST",
                                     headers={"Authorization": f"Bearer {KEY}", "Content-Type": "multipart/form-data; boundary=XyZ"})
        with urllib.request.urlopen(req, timeout=900) as r:
            data, ctype = r.read(), r.headers.get("Content-Type")
        detail = f"{ctype}, {len(data)} bytes"
        ok = ctype == "video/mp4" and data[4:8] == b"ftyp"
        if ffprobe and ok:
            path = os.path.join(tempfile.mkdtemp(), f"{op}.mp4")
            open(path, "wb").write(data)
            s = json.loads(subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
                                           "stream=width,height,nb_read_frames", "-of", "json", path], capture_output=True, text=True).stdout)["streams"][0]
            got = f"{s['width']}x{s['height']}"
            detail += f", {got}, {s['nb_read_frames']} frames"
            ok = got == size and int(s["nb_read_frames"]) == 16
        check(f"video-transform: {op} returns an MP4 of every frame", ok, detail)


def cache():
    """Prompt cache: a follow-up turn reports the shared history as cached, in OpenAI's and Anthropic's fields."""
    from anthropic import Anthropic
    from openai import OpenAI

    system = "\n".join(f"Rule {i}: answer briefly and stay on topic." for i in range(1, 150))
    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY)
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": "Name a primary color. One word."}]
    first = client.chat.completions.create(model="qwen3.5-0.8b", messages=msgs, max_tokens=8, temperature=0)
    msgs += [{"role": "assistant", "content": first.choices[0].message.content}, {"role": "user", "content": "Another one?"}]
    second = client.chat.completions.create(model="qwen3.5-0.8b", messages=msgs, max_tokens=8, temperature=0)
    cached = second.usage.prompt_tokens_details.cached_tokens
    check("chat completions: follow-up reports cached_tokens", cached > first.usage.prompt_tokens - 20,
          f"{cached} of {second.usage.prompt_tokens}")

    # Server-backed engines keep their own prefix cache (llama.cpp slots, mlx-vlm APC); Synapse relays their counts.
    listed = {m.id for m in client.models.list().data}
    for model in ("bartowski/Llama-3.2-1B-Instruct-GGUF", "gemma-3n-e2b"):
        if model not in listed:
            print(f"SKIP cache: {model} not downloaded")
            continue
        m = msgs[:2]
        r1 = client.chat.completions.create(model=model, messages=m, max_tokens=8, temperature=0)
        m += [{"role": "assistant", "content": r1.choices[0].message.content}, {"role": "user", "content": "Another one?"}]
        r2 = client.chat.completions.create(model=model, messages=m, max_tokens=8, temperature=0)
        got = r2.usage.prompt_tokens_details.cached_tokens
        check(f"{model}: follow-up reports cached_tokens", got > r1.usage.prompt_tokens - 40, f"{got} of {r2.usage.prompt_tokens}")

    ant = Anthropic(base_url=HOST, api_key=KEY)
    turns = [{"role": "user", "content": "Name a fruit. One word."}]
    a1 = ant.messages.create(model="qwen3.5-0.8b", system=system + "\nBe terse.", messages=turns, max_tokens=8)
    turns += [{"role": "assistant", "content": a1.content[0].text}, {"role": "user", "content": "Another one?"}]
    a2 = ant.messages.create(model="qwen3.5-0.8b", system=system + "\nBe terse.", messages=turns, max_tokens=8)
    check("anthropic: follow-up reports cache_read_input_tokens", a2.usage.cache_read_input_tokens > a1.usage.input_tokens - 20,
          f"read {a2.usage.cache_read_input_tokens}, uncached input {a2.usage.input_tokens}")


def sampling():
    """seed makes sampling reproducible on every engine; bad values are 400s."""
    import openai
    from openai import OpenAI

    client = OpenAI(base_url=f"{HOST}/v1", api_key=KEY, max_retries=0)
    listed = {m.id for m in client.models.list().data}
    prompt = [{"role": "user", "content": "Write one sentence about the sea."}]
    for model in ("qwen3.5-0.8b", "bartowski/Llama-3.2-1B-Instruct-GGUF", "gemma-3n-e2b"):
        if model not in listed:
            print(f"SKIP sampling: {model} not downloaded")
            continue
        def say(seed):
            return client.chat.completions.create(model=model, messages=prompt, max_tokens=30, temperature=0.9,
                                                  extra_body={"seed": seed, "top_k": 50, "min_p": 0.02}).choices[0].message.content
        a, b, c = say(11), say(11), say(12)
        check(f"{model}: same seed, same text", a == b, f"{a!r} / {b!r}")
        check(f"{model}: other seed, other text", a != c, f"{c!r}")
    try:
        client.chat.completions.create(model="qwen3.5-0.8b", messages=prompt, max_tokens=5, presence_penalty=3)
        check("presence_penalty 3 -> 400", False, "accepted")
    except openai.BadRequestError as e:
        check("presence_penalty 3 -> 400", True, str(e)[:80])


SECTIONS = {"cache": cache, "sampling": sampling, "speech": speech, "embeddings": embeddings, "rerank": rerank, "diarize": diarize, "video-input": video_input, "videos": videos, "sound": sound, "omni": omni, "chat-audio": chat_audio, "lmstudio": lmstudio, "models": models, "voices": voices, "image-embeddings": image_embeddings, "tools": tools, "audio-edit": audio_edit, "image-tools": image_tools, "video-transform": video_transform}

unknown = ONLY - SECTIONS.keys()
if unknown:
    sys.exit(f"unknown section(s): {', '.join(sorted(unknown))}; known: {', '.join(SECTIONS) or 'none yet'}")
for name, run in SECTIONS.items():
    if not ONLY or name in ONLY:
        print(f"== {name}")
        run()

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
