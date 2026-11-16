#!/usr/bin/env python3
"""Connects to Synapse the way an end user would: each official SDK gets only the host and the API key.

Checks OpenAI Chat Completions, legacy Completions and Responses (openai SDK) and Anthropic Messages (anthropic SDK),
each non-streaming and streaming, with the base URL given both as the bare host and as host/v1, so either convention
a client uses works. Responses are validated against the SDKs' own types.

Usage: python verify-connect.py <host-url> <api-key> [model]
  e.g. python verify-connect.py http://127.0.0.1:9000 sk-local qwen3.5-0.8b
"""
import sys

import anthropic
import openai
from openai.types import Completion
from openai.types.chat import ChatCompletion
from openai.types.responses import Response

HOST, KEY = sys.argv[1].rstrip("/"), sys.argv[2]
MODEL = sys.argv[3] if len(sys.argv) > 3 else "qwen3.5-0.8b"
ASK = "What is the capital of France? Answer with one word."
failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  [{detail}]" if detail else ""))
    if not ok:
        failures.append(label)


def attempt(label, fn):
    try:
        fn()
    except Exception as e:  # a protocol mismatch shows up as an SDK exception; report it, keep going
        check(label, False, f"{type(e).__name__}: {str(e)[:160]}")


for base in (HOST, HOST + "/v1"):
    oa = openai.OpenAI(base_url=base, api_key=KEY, timeout=600)
    tag = "host" if base == HOST else "host/v1"

    def chat():
        r = oa.chat.completions.create(model=MODEL, messages=[{"role": "user", "content": ASK}], temperature=0, max_tokens=16)
        ChatCompletion.model_validate(r.model_dump())
        check(f"[{tag}] openai chat.completions", "paris" in (r.choices[0].message.content or "").lower(), r.choices[0].message.content)

    def chat_stream():
        text, finish = "", None
        for c in oa.chat.completions.create(model=MODEL, messages=[{"role": "user", "content": ASK}], temperature=0,
                                            max_tokens=16, stream=True):
            if c.choices:
                text += c.choices[0].delta.content or ""
                finish = c.choices[0].finish_reason or finish
        check(f"[{tag}] openai chat.completions stream", "paris" in text.lower() and finish == "stop", f"{text!r} {finish}")

    def chat_stop():
        r = oa.chat.completions.create(model=MODEL, temperature=0, max_tokens=60, stop=["5"],
                                       messages=[{"role": "user", "content": "Count from 1 to 10, separated by commas. Only the numbers."}])
        t = r.choices[0].message.content or ""
        check(f"[{tag}] openai chat.completions stop", "4" in t and "5" not in t and "6" not in t and r.choices[0].finish_reason == "stop", repr(t))

    def legacy():
        r = oa.completions.create(model=MODEL, prompt="The capital of France is", temperature=0, max_tokens=8)
        Completion.model_validate(r.model_dump())
        check(f"[{tag}] openai completions", r.object == "text_completion" and "paris" in r.choices[0].text.lower()
              and r.usage.completion_tokens > 0, repr(r.choices[0].text))

    def legacy_stream():
        text, finish = "", None
        for c in oa.completions.create(model=MODEL, prompt="The capital of France is", temperature=0, max_tokens=8, stream=True):
            text += c.choices[0].text
            finish = c.choices[0].finish_reason or finish
        check(f"[{tag}] openai completions stream", "paris" in text.lower() and finish in ("stop", "length"), f"{text!r} {finish}")

    def responses():
        r = oa.responses.create(model=MODEL, input=ASK, temperature=0, max_output_tokens=16)
        Response.model_validate(r.model_dump())
        check(f"[{tag}] openai responses", "paris" in r.output_text.lower() and r.status == "completed", r.output_text)

    def responses_stream():
        text, done = "", False
        for e in oa.responses.create(model=MODEL, input=ASK, temperature=0, max_output_tokens=16, stream=True):
            if e.type == "response.output_text.delta":
                text += e.delta
            done = done or e.type == "response.completed"
        check(f"[{tag}] openai responses stream", "paris" in text.lower() and done, repr(text))

    for name, fn in [("chat", chat), ("chat stream", chat_stream), ("chat stop", chat_stop), ("completions", legacy),
                     ("completions stream", legacy_stream), ("responses", responses), ("responses stream", responses_stream)]:
        attempt(f"[{tag}] openai {name}", fn)

    an = anthropic.Anthropic(base_url=base, api_key=KEY, timeout=600)

    def messages():
        m = an.messages.create(model=MODEL, max_tokens=16, messages=[{"role": "user", "content": ASK}], extra_body={"temperature": 0})
        t = "".join(b.text for b in m.content if b.type == "text")
        check(f"[{tag}] anthropic messages", "paris" in t.lower() and m.stop_reason == "end_turn", repr(t))

    def messages_stream():
        with an.messages.stream(model=MODEL, max_tokens=16, messages=[{"role": "user", "content": ASK}], extra_body={"temperature": 0}) as s:
            t = "".join(s.text_stream)
            final = s.get_final_message()
        check(f"[{tag}] anthropic messages stream", "paris" in t.lower() and final.stop_reason == "end_turn", repr(t))

    attempt(f"[{tag}] anthropic messages", messages)
    attempt(f"[{tag}] anthropic messages stream", messages_stream)

# A wrong key must be refused in each protocol's own error shape, so each SDK raises its auth error.
try:
    openai.OpenAI(base_url=HOST, api_key="wrong").models.list()
    check("openai wrong key -> AuthenticationError", False)
except openai.AuthenticationError:
    check("openai wrong key -> AuthenticationError", True)
try:
    anthropic.Anthropic(base_url=HOST, api_key="wrong").messages.create(model=MODEL, max_tokens=5, messages=[{"role": "user", "content": "hi"}])
    check("anthropic wrong key -> AuthenticationError", False)
except anthropic.AuthenticationError:
    check("anthropic wrong key -> AuthenticationError", True)

print(f"\n{'ALL PASSED' if not failures else f'{len(failures)} FAILED: ' + ', '.join(failures)}")
sys.exit(1 if failures else 0)
