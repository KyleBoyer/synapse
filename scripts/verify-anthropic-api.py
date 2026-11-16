#!/usr/bin/env python3
"""Checks Synapse's Anthropic Messages endpoints against the official Anthropic Python SDK.

Raw responses and stream events are validated against the SDK's own pydantic types, because its normal
parsing is lenient and would hide missing or mistyped fields.

Usage: python verify-anthropic-api.py [base_url] [model]
  defaults: http://127.0.0.1:9000  qwen3.5-0.8b   (base_url has no /v1: the SDK adds it)
Set SYNAPSE_API_KEY when LAN mode (API key) is on.
"""
import base64, json, os, sys, urllib.request
from pathlib import Path

import anthropic
from anthropic.types import Message, MessageTokensCount, ModelInfo, RawMessageStreamEvent
from pydantic import TypeAdapter

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9000"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "qwen3.5-0.8b"
FIX = Path(__file__).resolve().parent.parent / "Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures"
client = anthropic.Anthropic(base_url=BASE, api_key=os.environ.get("SYNAPSE_API_KEY", "unused"), timeout=600)
event_adapter = TypeAdapter(RawMessageStreamEvent)
failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  [{detail}]" if detail else ""))
    if not ok:
        failures.append(label)


def strict(model_cls, raw):
    return model_cls.model_validate(raw, strict=False)


def image(name, mime):
    return {"type": "image", "source": {"type": "base64", "media_type": mime,
                                        "data": base64.b64encode((FIX / name).read_bytes()).decode()}}


def raw_post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST", headers={
        "Content-Type": "application/json", "x-api-key": client.api_key, "anthropic-version": "2023-06-01"})
    return urllib.request.urlopen(req, timeout=600)


def text_of(msg):
    return "".join(b.text for b in msg.content if b.type == "text")


ask = [{"role": "user", "content": "What is the capital of France? Answer with one word."}]

# models.list
models = list(client.models.list())
check("models.list includes " + MODEL, MODEL in [m.id for m in models], ", ".join(m.id for m in models))
with urllib.request.urlopen(urllib.request.Request(BASE + "/v1/models", headers={"x-api-key": client.api_key})) as r:
    for item in json.load(r)["data"]:
        strict(ModelInfo, item)
check("models.list items validate as ModelInfo", True)

# Plain message, raw body validated.
with raw_post("/v1/messages", {"model": MODEL, "max_tokens": 64, "temperature": 0, "messages": ask}) as r:
    raw = json.load(r)
m = strict(Message, raw)
check("messages.create schema + answer", "paris" in text_of(m).lower() and m.stop_reason == "end_turn"
      and m.usage.input_tokens > 0 and m.usage.output_tokens > 0, repr(text_of(m)))
check("message id/type/role", m.id.startswith("msg_") and m.type == "message" and m.role == "assistant")

# claude-* ids map to the default chat model.
m = client.messages.create(model="claude-sonnet-4-5", max_tokens=64, extra_body={"temperature": 0}, messages=ask)
check("claude-* model id falls back to the local model", "paris" in text_of(m).lower(), f"{m.model}: {text_of(m)!r}")

# System prompt.
m = client.messages.create(model=MODEL, max_tokens=64, extra_body={"temperature": 0}, system="Reply only in uppercase letters.",
                           messages=[{"role": "user", "content": "Say hello."}])
check("system prompt applied", text_of(m).strip() and text_of(m) == text_of(m).upper(), repr(text_of(m)))

# Raw stream: every event validates, the SSE event name equals its type, order is right.
types, names, text = [], [], ""
with raw_post("/v1/messages", {"model": MODEL, "max_tokens": 64, "temperature": 0, "stream": True, "messages": ask}) as r:
    event = None
    for line in (l.decode().rstrip("\n") for l in r):
        if line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: "):
            e = event_adapter.validate_python(json.loads(line[6:]))
            types.append(e.type); names.append(event)
            if e.type == "content_block_delta" and e.delta.type == "text_delta":
                text += e.delta.text
order_ok = (types[0] == "message_start" and types[-2:] == ["message_delta", "message_stop"]
            and "content_block_start" in types and names == types)
check("stream raw events validate + order + event names", order_ok, " > ".join(dict.fromkeys(types)))
check("stream text", "paris" in text.lower(), repr(text))

# SDK stream helper.
with client.messages.stream(model=MODEL, max_tokens=64, extra_body={"temperature": 0}, messages=ask) as s:
    streamed = "".join(s.text_stream)
    final = s.get_final_message()
check("messages.stream helper", "paris" in streamed.lower() and final.stop_reason == "end_turn"
      and final.usage.output_tokens > 0, repr(streamed))

# Vision.
for name, mime, animal in [("zebra.jpg", "image/jpeg", "zebra"), ("penguin.png", "image/png", "penguin")]:
    m = client.messages.create(model=MODEL, max_tokens=48, extra_body={"temperature": 0}, messages=[{"role": "user", "content": [
        image(name, mime), {"type": "text", "text": "What animal is in this picture? One word."}]}])
    check(f"vision ({name})", animal in text_of(m).lower(), repr(text_of(m)))

# max_tokens.
m = client.messages.create(model=MODEL, max_tokens=5, messages=[{"role": "user", "content": "Write a long story about a dragon."}])
check("stop_reason=max_tokens", m.stop_reason == "max_tokens" and m.usage.output_tokens == 5, f"{m.stop_reason} {m.usage}")

# stop_sequences.
m = client.messages.create(model=MODEL, max_tokens=80, extra_body={"temperature": 0}, stop_sequences=["5"],
                           messages=[{"role": "user", "content": "Count from 1 to 10, separated by commas. Only the numbers."}])
check("stop_sequences", m.stop_reason == "stop_sequence" and m.stop_sequence == "5" and "6" not in text_of(m),
      f"{m.stop_reason} {m.stop_sequence!r} {text_of(m)!r}")

# Extended thinking. Sampled, as Qwen recommends for thinking mode. Small models sometimes think until max_tokens,
# so every attempt must be well formed and one of three must finish with an answer.
results = []
for _ in range(3):
    m = client.messages.create(model=MODEL, max_tokens=4000, thinking={"type": "enabled", "budget_tokens": 3000},
                               messages=[{"role": "user", "content": "What is 2 + 2? Reply with just the number."}])
    kinds = [b.type for b in m.content]
    well_formed = kinds[:1] == ["thinking"] and "</think>" not in text_of(m) and (
        m.stop_reason == "max_tokens" or (m.stop_reason == "end_turn" and kinds[-1] == "text"))
    results.append((well_formed, m.stop_reason == "end_turn" and "4" in text_of(m), m.stop_reason, len(kinds)))
    if results[-1][1]:
        break
check("thinking block then text block", all(r[0] for r in results) and results[-1][1], str(results))

# Tool use round trip.
tools = [{"name": "get_weather", "description": "Get the current weather for a city.",
          "input_schema": {"type": "object", "properties": {"city": {"type": "string", "description": "City name"}},
                           "required": ["city"]}}]
# The 0.8B model only calls a tool when asked to outright; larger models decide on their own.
convo = [{"role": "user", "content": "Call get_weather for Paris."}]
m = client.messages.create(model=MODEL, max_tokens=400, extra_body={"temperature": 0}, tools=tools, messages=convo)
use = next((b for b in m.content if b.type == "tool_use"), None)
check("tool_use block + stop_reason=tool_use", use is not None and m.stop_reason == "tool_use" and use.name == "get_weather"
      and "paris" in json.dumps(use.input).lower() and use.id.startswith("toolu_"), f"{m.stop_reason} {m.content}")
if use:
    convo += [{"role": "assistant", "content": m.content},
              {"role": "user", "content": [{"type": "tool_result", "tool_use_id": use.id,
                                            "content": "Sunny, 31 degrees Celsius."}]}]
    m2 = client.messages.create(model=MODEL, max_tokens=200, extra_body={"temperature": 0}, tools=tools, messages=convo)
    check("tool_result answered", "31" in text_of(m2) or "sunny" in text_of(m2).lower(), repr(text_of(m2)))

# Tool use while streaming: the helper accumulates input_json_delta into the block's input.
with client.messages.stream(model=MODEL, max_tokens=400, extra_body={"temperature": 0}, tools=tools, messages=convo[:1]) as s:
    final = s.get_final_message()
use = next((b for b in final.content if b.type == "tool_use"), None)
check("streamed tool_use input", use is not None and isinstance(use.input, dict) and "city" in use.input, f"{final.content}")

# count_tokens.
with raw_post("/v1/messages/count_tokens", {"model": MODEL, "messages": ask}) as r:
    c = strict(MessageTokensCount, json.load(r))
sdk_count = client.messages.count_tokens(model=MODEL, messages=ask)
check("count_tokens", c.input_tokens > 5 and sdk_count.input_tokens == c.input_tokens, str(c.input_tokens))

# Errors use Anthropic's shape so the SDK raises the right class.
try:
    client.messages.create(model="no-such-model", max_tokens=5, messages=ask)
    check("unknown model -> 400", False)
except anthropic.BadRequestError as e:
    check("unknown model -> BadRequestError", e.body.get("type") == "error" and "message" in e.body.get("error", {}), str(e.body)[:120])

print(f"\n{'ALL PASSED' if not failures else f'{len(failures)} FAILED: ' + ', '.join(failures)}")
sys.exit(1 if failures else 0)
