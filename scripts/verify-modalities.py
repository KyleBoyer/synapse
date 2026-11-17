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


# name -> function; milestones register their sections here.
SECTIONS = {"speech": speech, "embeddings": embeddings, "rerank": rerank}

unknown = ONLY - SECTIONS.keys()
if unknown:
    sys.exit(f"unknown section(s): {', '.join(sorted(unknown))}; known: {', '.join(SECTIONS) or 'none yet'}")
for name, run in SECTIONS.items():
    if not ONLY or name in ONLY:
        print(f"== {name}")
        run()

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
