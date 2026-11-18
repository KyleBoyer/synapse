#!/usr/bin/env python3
"""Checks Synapse's /v1/realtime against the official OpenAI SDK.

Every server event is validated with the SDK's pydantic types (strict validation, not the SDK's lenient
construct). Speech comes from macOS `say`, resampled to 24 kHz PCM16 and streamed in chunks.

  scripts/with-gpu-lock.sh <python> scripts/verify-openai-realtime.py --base-url http://127.0.0.1:19100/v1 --model qwen3.5-0.8b
"""
import argparse, asyncio, base64, json, os, subprocess, sys, tempfile, time, wave
import numpy as np
from openai import AsyncOpenAI
from pydantic import TypeAdapter
from openai.types.realtime import RealtimeServerEvent

ADAPTER = TypeAdapter(RealtimeServerEvent)
RATE = 24000


def say(text: str) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "s.wav")
        subprocess.run(["say", "-v", "Samantha", "-o", path, f"--data-format=LEI16@{RATE}", text], check=True)
        with wave.open(path) as w:
            assert w.getframerate() == RATE and w.getnchannels() == 1
            return w.readframes(w.getnframes())


def silence(sec: float) -> bytes:
    return b"\x00\x00" * int(RATE * sec)


class Checker:
    def __init__(self, conn):
        self.conn = conn
        self.events = []      # (time, validated dict)
        self.errors = []
        self.reader = asyncio.create_task(self._read())

    async def _read(self):
        try:
            while True:
                raw = json.loads(await self.conn.recv_bytes())
                try:
                    ADAPTER.validate_python(raw)
                except Exception as e:  # strict failure
                    self.errors.append(f"{raw.get('type')}: {str(e)[:600]}")
                self.events.append((time.monotonic(), raw))
        except Exception:
            pass

    def of(self, t):
        return [e for _, e in self.events if e["type"] == t]

    async def wait(self, t, n=1, timeout=90, after=0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if len([1 for i, (_, e) in enumerate(self.events) if i >= after and e["type"] == t]) >= n:
                return True
            await asyncio.sleep(0.02)
        return False

    def when(self, t, nth=0):
        xs = [ts for ts, e in self.events if e["type"] == t]
        return xs[nth] if len(xs) > nth else None

    async def send_audio(self, pcm: bytes, speed=4.0):
        step = int(RATE * 0.1) * 2  # 100 ms
        for i in range(0, len(pcm), step):
            await self.conn.send({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm[i:i + step]).decode()})
            await asyncio.sleep(0.1 / speed)

    def close(self):
        self.reader.cancel()


def words(s):
    return {w.strip(".,?!").lower() for w in s.split()}


failures = []


def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)


async def run(args):
    client = AsyncOpenAI(base_url=args.base_url, api_key=args.api_key)

    # 1. Live transcription
    q = "The quick brown fox jumps over the lazy dog near the river."
    async with client.realtime.connect(extra_query={"intent": "transcription"}) as conn:
        c = Checker(conn)
        check(await c.wait("session.created", timeout=10), "transcription: session.created")
        check(c.of("session.created")[0]["session"]["type"] == "transcription", "transcription: session type")
        await conn.send({"type": "session.update", "session": {"type": "transcription", "audio": {"input": {
            "transcription": {"model": "parakeet-eou-120m", "language": "en"},
            "turn_detection": {"type": "server_vad", "silence_duration_ms": 500}}}}})
        check(await c.wait("session.updated", timeout=10), "transcription: session.updated")
        await c.send_audio(silence(0.5) + say(q) + silence(1.5))
        ok = await c.wait("conversation.item.input_audio_transcription.completed", timeout=60)
        check(ok, "transcription: completed event")
        if ok:
            t = c.of("conversation.item.input_audio_transcription.completed")[0]["transcript"]
            overlap = len(words(t) & words(q)) / len(words(q))
            print(f"      transcript: {t!r} (word overlap {overlap:.0%})")
            check(overlap >= 0.6, "transcription: transcript matches speech")
        check(len(c.of("conversation.item.input_audio_transcription.delta")) > 0, "transcription: streamed deltas")
        check(not c.of("response.created"), "transcription: no response generated")
        c.close(); errs = c.errors
        check(not errs, "transcription: all events pass strict SDK validation" + ("" if not errs else f" {errs[:2]}"))

    # 2. Cascaded voice call
    async with client.realtime.connect(model=args.model) as conn:
        c = Checker(conn)
        await c.wait("session.created", timeout=10)
        await conn.send({"type": "session.update", "session": {"type": "realtime", "instructions":
                         "You are a friendly assistant. Answer in one short sentence.",
                         "output_modalities": ["audio"],
                         "audio": {"input": {"turn_detection": {"type": "server_vad", "silence_duration_ms": 500}},
                                   "output": {"voice": "alloy"}}}})
        await c.wait("session.updated", timeout=10)
        await c.send_audio(silence(0.5) + say("What is the capital of France?") + silence(2.0))
        ok = await c.wait("response.done", timeout=120)
        check(ok, "call: response.done")
        if ok:
            r = c.of("response.done")[0]["response"]
            check(r["status"] == "completed", f"call: response completed ({r['status']})")
            tr = "".join(e["delta"] for e in c.of("response.output_audio_transcript.delta"))
            print(f"      user: {c.of('conversation.item.input_audio_transcription.completed')[0]['transcript']!r}")
            print(f"      assistant: {tr!r}")
            pcm = b"".join(base64.b64decode(e["delta"]) for e in c.of("response.output_audio.delta"))
            a = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
            rms = float(np.sqrt((a ** 2).mean())) if len(a) else 0
            print(f"      reply audio: {len(a) / RATE:.1f}s, rms {rms:.0f}")
            check(len(a) > RATE * 0.5 and rms > 200, "call: spoken reply is non-silent PCM")
            check(len(tr) > 0, "call: reply transcript streamed")
            t0, t1 = c.when("input_audio_buffer.speech_stopped"), c.when("response.output_audio.delta")
            print(f"      latency speech_stopped -> first audio delta: {t1 - t0:.2f}s")
        c.close()
        check(not c.errors, "call: all events pass strict SDK validation" + ("" if not c.errors else f" {c.errors[:2]}"))
        check(not c.of("error"), f"call: no error events {c.of('error')[:1]}")

        # Second turn on the same connection: models are warm, so this is the steady-state latency.
        c = Checker(conn)
        await c.send_audio(say("And what is the capital of Italy?") + silence(2.0))
        if await c.wait("response.done", timeout=120):
            t0, t1 = c.when("input_audio_buffer.speech_stopped"), c.when("response.output_audio.delta")
            print(f"      warm turn: {''.join(e['delta'] for e in c.of('response.output_audio_transcript.delta'))!r}")
            print(f"      warm latency speech_stopped -> first audio delta: {t1 - t0:.2f}s")
            check(c.of("response.done")[0]["response"]["status"] == "completed", "call: second turn completed")
        c.close()
        check(not c.errors, "call: second turn passes strict SDK validation")

        # 3. Barge-in on the same connection
        c = Checker(conn)
        await conn.send({"type": "session.update", "session": {"type": "realtime",
                         "instructions": "Tell long stories. Always answer with at least ten sentences."}})
        await c.send_audio(say("Tell me a long story about a dragon and a knight.") + silence(1.5))
        check(await c.wait("response.output_audio.delta", timeout=120), "barge-in: reply started")
        mark = len(c.events)
        await c.send_audio(say("Stop, wait a moment, I have a question.") + silence(1.0))
        ok = await c.wait("response.done", timeout=60)
        check(ok, "barge-in: response.done after interruption")
        if ok:
            r = c.of("response.done")[0]["response"]
            check(r["status"] == "cancelled", f"barge-in: first response cancelled ({r['status']})")
            idx = [i for i, (_, e) in enumerate(c.events) if e["type"] == "response.done"][0]
            late = [e for _, e in c.events[idx + 1:] if e["type"] == "response.output_audio.delta"
                    and e["response_id"] == r["id"]]
            check(not late, "barge-in: no audio from the cancelled response after response.done")
        check(await c.wait("response.done", n=2, timeout=120), "barge-in: second turn answered")
        c.close()
        check(not c.errors, "barge-in: events pass strict SDK validation" + ("" if not c.errors else f" {c.errors[:2]}"))

    # 4. Translation (text out) and text-only output
    async with client.realtime.connect(model=args.model) as conn:
        c = Checker(conn)
        await c.wait("session.created", timeout=10)
        await conn.send({"type": "session.update", "session": {"type": "realtime", "output_modalities": ["text"],
                         "translation_language": "Spanish"}})
        await c.wait("session.updated", timeout=10)
        await c.send_audio(silence(0.5) + say("Good morning, how are you today?") + silence(2.0))
        ok = await c.wait("response.done", timeout=120)
        check(ok, "translation: response.done")
        if ok:
            text = "".join(e["delta"] for e in c.of("response.output_text.delta"))
            print(f"      translation: {text!r}")
            check(len(text) > 0 and not c.of("response.output_audio.delta"), "translation: text-only output")
        c.close()
        check(not c.errors, "translation: events pass strict SDK validation" + ("" if not c.errors else f" {c.errors[:2]}"))

    # 5. Error events
    async with client.realtime.connect(model=args.model) as conn:
        c = Checker(conn)
        await c.wait("session.created", timeout=10)
        await conn.send_raw("not json")
        await conn.send({"type": "no.such.event"})
        check(await c.wait("error", n=2, timeout=10), "errors: bad JSON and unknown type produce error events")
        c.close()
        check(not c.errors, "errors: events pass strict SDK validation" + ("" if not c.errors else f" {c.errors[:2]}"))

    # 6. Tool calls, in both kinds of voice call: assembled (--tools-model, a chat model) and omni (--omni-model).
    weather = {"type": "function", "name": "get_weather", "description": "Current weather for a city.",
               "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}
    for label, model in [("tools", args.tools_model), ("omni tools", args.omni_model)]:
        if not model:
            continue
        async with client.realtime.connect(model=model) as conn:
            c = Checker(conn)
            await c.wait("session.created", timeout=10)
            await conn.send({"type": "session.update", "session": {"type": "realtime", "tools": [weather], "tool_choice": "auto",
                             "instructions": "You are a voice assistant. Use tools when they help. Answer in one short sentence."}})
            await conn.send({"type": "conversation.item.create", "item": {"type": "message", "role": "user",
                             "content": [{"type": "input_text", "text": "What's the weather like in Paris right now?"}]}})
            await conn.send({"type": "response.create"})
            check(await c.wait("response.done", timeout=300), f"{label}: first response done")
            done = c.of("response.function_call_arguments.done")
            check(done and done[0]["name"] == "get_weather" and "paris" in done[0]["arguments"].lower(),
                  f"{label}: {model} calls get_weather for Paris" + ("" if done else f" (said {''.join(e['delta'] for e in c.of('response.output_audio_transcript.delta'))!r})"))
            if done:
                await conn.send({"type": "conversation.item.create", "item": {"type": "function_call_output", "call_id": done[0]["call_id"],
                                 "output": json.dumps({"city": "Paris", "temperature_c": 18, "sky": "light rain"})}})
                await conn.send({"type": "response.create"})
                check(await c.wait("response.done", n=2, timeout=300), f"{label}: answer after the tool result")
                said = "".join(e["delta"] for e in c.of("response.output_audio_transcript.delta"))
                check("18" in said or "rain" in said.lower(), f"{label}: the spoken answer uses the result ({said!r})")
            c.close()
            check(not c.errors, f"{label}: events pass strict SDK validation" + ("" if not c.errors else f" {c.errors[:2]}"))

    print("\n%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://127.0.0.1:19100/v1")
    p.add_argument("--api-key", default="synapse")
    p.add_argument("--model", default="qwen3.5-0.8b")
    p.add_argument("--tools-model", default="qwen3.5-2b", help="chat model for the assembled tool-call check (empty to skip)")
    p.add_argument("--omni-model", default="lfm3-omni-2b", help="omni model for the tool-call check (empty to skip)")
    sys.exit(asyncio.run(run(p.parse_args())))
