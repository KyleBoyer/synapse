#!/usr/bin/env python3
"""Checks Synapse's chat endpoints against the official OpenAI Python SDK.

Every raw response and stream event is validated against the SDK's own pydantic models
(the SDK's normal parsing is lenient and would hide missing or mistyped fields).

Usage: python verify-openai-api.py [base_url] [model]
  defaults: http://127.0.0.1:9000/v1  qwen3.5-0.8b
Set SYNAPSE_API_KEY when LAN mode (API key) is on.
"""
import base64, json, os, sys, time, urllib.request
from pathlib import Path

from openai import OpenAI
from openai.types.chat import ChatCompletion, ChatCompletionChunk
from openai.types.responses import Response, ResponseStreamEvent
from pydantic import TypeAdapter

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9000/v1"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "qwen3.5-0.8b"
FIX = Path(__file__).resolve().parent.parent / "Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures"
client = OpenAI(base_url=BASE, api_key=os.environ.get("SYNAPSE_API_KEY", "unused"), timeout=600)
event_adapter = TypeAdapter(ResponseStreamEvent)
failures = []


def data_url(name, mime):
    return f"data:{mime};base64," + base64.b64encode((FIX / name).read_bytes()).decode()


def sse_lines(path, body):
    """Raw SSE `data:` payloads straight off the wire (no SDK parsing)."""
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST", headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {client.api_key}"})
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            line = raw.decode().rstrip("\n")
            if line.startswith("data: "):
                yield line[6:]


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  [{detail}]" if detail else ""))
    if not ok:
        failures.append(label)


def strict(model_cls, raw):
    model_cls.model_validate(raw)  # raises on missing or mistyped required fields
    return raw


ZEBRA = data_url("zebra.jpg", "image/jpeg")
PENGUIN = data_url("penguin.png", "image/png")
ANIMAL_Q = "What animal is in this picture? Answer in one word."

# --- models
ids = [m.id for m in client.models.list().data]
check("models.list includes " + MODEL, MODEL in ids, ", ".join(ids))

# --- chat.completions, text, non-streaming
t = time.time()
raw = client.chat.completions.with_raw_response.create(
    model=MODEL, messages=[{"role": "system", "content": "You are terse."},
                           {"role": "user", "content": "What is 2 + 2? Reply with only the number."}],
    max_tokens=16, temperature=0)
body = strict(ChatCompletion, json.loads(raw.text))
c = raw.parse()
check("chat.completions text schema + answer", "4" in c.choices[0].message.content,
      f"{c.choices[0].message.content!r} finish={c.choices[0].finish_reason} usage={c.usage.model_dump()} {time.time()-t:.1f}s")
check("chat.completions object/id", body["object"] == "chat.completion" and body["id"].startswith("chatcmpl-"))

# --- chat.completions, streaming with usage
chunks, text, usage = 0, "", None
stream = client.chat.completions.create(
    model=MODEL, messages=[{"role": "user", "content": "Name three primary colors, comma separated."}],
    max_tokens=40, temperature=0, stream=True, stream_options={"include_usage": True})
finish = None
for ch in stream:
    chunks += 1
    if ch.choices:
        text += ch.choices[0].delta.content or ""
        finish = ch.choices[0].finish_reason or finish
    if ch.usage:
        usage = ch.usage
check("chat.completions stream", chunks > 2 and "red" in text.lower() and finish in ("stop", "length") and usage is not None,
      f"{chunks} chunks {text!r} finish={finish} usage={usage and usage.model_dump()}")

raw_chunks = 0
last = None
for data in sse_lines("/chat/completions", {"model": MODEL, "max_tokens": 10, "stream": True,
                                            "stream_options": {"include_usage": True},
                                            "messages": [{"role": "user", "content": "Say hi."}]}):
    last = data
    if data != "[DONE]":
        ChatCompletionChunk.model_validate(json.loads(data))
        raw_chunks += 1
check("chat.completions raw chunks validate, ends with [DONE]", raw_chunks > 1 and last == "[DONE]", f"{raw_chunks} chunks")

# --- chat.completions, vision (image_url data URL)
for name, url, animal in [("zebra", ZEBRA, "zebra"), ("penguin", PENGUIN, "penguin")]:
    raw = client.chat.completions.with_raw_response.create(
        model=MODEL, max_tokens=16, temperature=0,
        messages=[{"role": "user", "content": [
            {"type": "text", "text": ANIMAL_Q},
            {"type": "image_url", "image_url": {"url": url}}]}])
    strict(ChatCompletion, json.loads(raw.text))
    out = raw.parse().choices[0].message.content
    check(f"chat.completions vision ({name})", animal in out.lower(), repr(out))

# --- max_tokens -> finish_reason length
c = client.chat.completions.create(model=MODEL, max_tokens=5, temperature=0,
                                   messages=[{"role": "user", "content": "Count from 1 to 50."}])
check("chat.completions finish_reason=length", c.choices[0].finish_reason == "length" and c.usage.completion_tokens == 5,
      f"{c.choices[0].finish_reason} {c.usage.completion_tokens}")

# --- responses, text
raw = client.responses.with_raw_response.create(
    model=MODEL, instructions="You are terse.", input="What is the capital of France? One word.",
    max_output_tokens=16, temperature=0)
strict(Response, json.loads(raw.text))
r = raw.parse()
check("responses text schema + output_text", "paris" in r.output_text.lower() and r.status == "completed",
      f"{r.output_text!r} status={r.status} usage={r.usage.model_dump()}")

# --- responses, vision (input_image)
for name, url, animal in [("zebra", ZEBRA, "zebra"), ("penguin", PENGUIN, "penguin")]:
    raw = client.responses.with_raw_response.create(
        model=MODEL, max_output_tokens=16, temperature=0,
        input=[{"role": "user", "content": [
            {"type": "input_text", "text": ANIMAL_Q},
            {"type": "input_image", "image_url": url}]}])
    strict(Response, json.loads(raw.text))
    out = raw.parse().output_text
    check(f"responses vision ({name})", animal in out.lower(), repr(out))

# --- responses, streaming (with image): validate every raw SSE event off the wire, then the SDK helper
stream_body = {"model": MODEL, "max_output_tokens": 16, "temperature": 0, "stream": True,
               "input": [{"role": "user", "content": [
                   {"type": "input_text", "text": ANIMAL_Q}, {"type": "input_image", "image_url": ZEBRA}]}]}
types, deltas = [], ""
for data in sse_lines("/responses", stream_body):
    ev = event_adapter.validate_python(json.loads(data))
    types.append(ev.type)
    if ev.type == "response.output_text.delta":
        deltas += ev.delta
expected = ["response.created", "response.in_progress", "response.output_item.added", "response.content_part.added",
            "response.output_text.delta", "response.output_text.done", "response.content_part.done",
            "response.output_item.done", "response.completed"]
order_ok = [t for i, t in enumerate(types) if i == 0 or t != types[i - 1]] == expected
check("responses stream raw events validate + order", order_ok, " > ".join(dict.fromkeys(types)))
check("responses stream vision text", "zebra" in deltas.lower(), repr(deltas))
with client.responses.stream(**{k: v for k, v in stream_body.items() if k != "stream"}) as s:
    final = s.get_final_response()
check("responses.stream SDK helper final response", "zebra" in final.output_text.lower(), repr(final.output_text))

# --- error shape
try:
    client.chat.completions.create(model="no-such-model", messages=[{"role": "user", "content": "hi"}])
    check("unknown model -> 400", False)
except Exception as e:
    check("unknown model -> 400 OpenAI error", getattr(e, "status_code", None) == 400, str(e)[:120])

print(f"\n{len(failures)} failure(s)" + (": " + ", ".join(failures) if failures else ""))
sys.exit(1 if failures else 0)
