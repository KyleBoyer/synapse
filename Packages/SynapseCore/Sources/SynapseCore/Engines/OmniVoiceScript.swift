/// Python sidecar that keeps an omni model loaded and answers in its own voice, streaming as it speaks.
/// It uses the functions mlx-vlm's CLI uses for `--output-modality audio` (load, apply_chat_template with
/// use_tts_template, the model's speech sampler and codec), but loads the model once instead of once per turn.
///
/// Request (one line): {"id", "messages": [{"role", "content"}], "images": [path], "audios": [path], "max_tokens", "temperature",
///                      "tools"?: [chat-template function tools]}
/// Cancel (any time):  {"cancel": id}
/// Replies, each a line starting with "SYNAPSE ":
///   {"id", "text": delta}                                  transcript as it is generated
///   {"id", "audio": base64 float32 LE, "sample_rate"}      speech as it is generated
///   {"id", "tool_calls": [{"name", "arguments": JSON}]}    the model called tools instead of speaking
///   {"id", "done": true, "cancelled", "prompt_tokens", "generation_tokens"}  or  {"id", "error"}
enum OmniVoiceScript {
    static let source = #"""
import base64, json, os, re, select, sys, threading, time, traceback

parent = os.getppid()
def watch():
    # Exit with Synapse: a child outlives a parent that quits or crashes, and this one holds a model.
    while True:
        time.sleep(1)
        if os.getppid() != parent:
            os._exit(0)
threading.Thread(target=watch, daemon=True).start()

import mlx.core as mx
import numpy as np
from mlx_vlm import load
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import prepare_inputs, should_add_special_tokens
from mlx_vlm.generate.common import generation_stream, wired_limit
from mlx_vlm.generate.audio import generate_audio, is_audio_generation_model

def reply(obj):
    sys.stdout.write("SYNAPSE " + json.dumps(obj) + "\n")
    sys.stdout.flush()

def send_audio(rid, samples, rate):
    if samples.size:
        reply({"id": rid, "audio": base64.b64encode(samples.astype("<f4").tobytes()).decode(), "sample_rate": rate})

model, processor = load(sys.argv[1])
if not is_audio_generation_model(model):
    reply({"fatal": "This model cannot speak (no generate_audio)."})
    sys.exit(1)
tokenizer = getattr(processor, "tokenizer", processor)

# Models that sample text and speech in one loop (LFM) can stream. Their cards recommend these speech sampling
# settings, and "interleaved" forces text with speech (the system prompt only encourages it).
joint = getattr(model, "joint_audio_text_generation", False) and callable(getattr(model, "stream_slots", None))
if joint and isinstance(getattr(model, "audio_sampling", None), dict):
    model.audio_sampling.update({"audio_temperature": 0.4, "audio_repetition_penalty": 1.2})
SPEAK = "Respond in interleaved text and audio."
STEP, HOLD = 6, 2   # re-decode every 6 frames (~0.5 s); hold back 2 frames, since the codec looks ahead

def with_voice_instruction(messages):
    if not joint:
        return messages
    msgs = [dict(m) for m in messages]
    if msgs and msgs[0].get("role") == "system":
        msgs[0]["content"] = (msgs[0].get("content") or "").rstrip() + "\n" + SPEAK
    else:
        msgs.insert(0, {"role": "system", "content": SPEAK})
    return msgs

pending = []
def cancelled(rid):
    """Reads any lines waiting on stdin without blocking; True if one cancels this request."""
    hit = False
    while select.select([sys.stdin], [], [], 0)[0]:
        line = sys.stdin.readline()
        if not line:
            break
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("cancel") == rid:
            hit = True
        elif "cancel" not in msg:
            pending.append(msg)
    return hit

TOOL = "<tool_call>"

def parse_tool_calls(text):
    """The XML tool calls LFM3 writes: <function=name><parameter=key>value</parameter>...</function>."""
    calls = []
    for name, body in re.findall(r"<function=([^>\n]+)>\s*(.*?)</function>", text, re.S):
        args = {}
        for key, value in re.findall(r"<parameter=([^>\n]+)>\n?(.*?)\n?</parameter>", body, re.S):
            value = value.strip()
            try:
                args[key.strip()] = json.loads(value)
            except ValueError:
                args[key.strip()] = value
        calls.append({"name": name.strip(), "arguments": json.dumps(args)})
    return calls

def probe_tools(req, images, audios):
    """In speech mode LFM3 answers instead of calling a tool, so a text-only pass decides first. A reply that does not
    open with <tool_call> stops within a few tokens and the turn is spoken; one that does is finished and returned."""
    cfg = model.config
    prompt = apply_chat_template(processor, cfg, req["messages"], num_images=len(images), num_audios=len(audios),
                                 use_tts_template=True, tools=req["tools"])
    inputs = prepare_inputs(processor, images=images or None, audio=audios or None, prompts=prompt,
                            add_special_tokens=should_add_special_tokens(cfg.model_type, processor))
    input_ids = inputs.pop("input_ids")
    inputs.pop("attention_mask", None)
    ids = []
    with wired_limit(model, [generation_stream]), mx.stream(generation_stream):
        for token, codes in model.stream_slots(input_ids, generation_mode="text", **model.audio_sampling, **inputs, max_tokens=400):
            if codes is not None or token == cfg.audio_out_token_id:
                continue
            ids.append(token)
            head = tokenizer.decode(ids, skip_special_tokens=False).lstrip()
            if head and not (TOOL.startswith(head) or head.startswith(TOOL)):
                return None
            if "<|im_end|>" in head or "<|text_end|>" in head:
                break
    return parse_tool_calls(tokenizer.decode(ids, skip_special_tokens=False)) or None

def stream_joint(req, prompt, images, audios):
    rid = req["id"]
    if req.get("tools"):
        calls = probe_tools(req, images, audios)
        if calls:
            reply({"id": rid, "tool_calls": calls})
            reply({"id": rid, "done": True, "cancelled": False, "prompt_tokens": 0, "generation_tokens": 0})
            return
    cfg = model.config
    inputs = prepare_inputs(processor, images=images or None, audio=audios or None, prompts=prompt,
                            add_special_tokens=should_add_special_tokens(cfg.model_type, processor))
    input_ids = inputs.pop("input_ids")
    inputs.pop("attention_mask", None)
    codec = model.codec()
    rate = int(codec.config.sampling_rate)
    kwargs = {**model.audio_sampling, **inputs, "max_tokens": int(req.get("max_tokens") or 512)}
    if req.get("temperature") is not None:
        kwargs["temperature"] = float(req["temperature"])
    frames, text_ids, sent_text, emitted, decoded_at, n = [], [], "", 0, 0, 0
    stop = False
    with wired_limit(model, [generation_stream]), mx.stream(generation_stream):
        for token, codes in model.stream_slots(input_ids, generation_mode="interleaved", **kwargs):
            n += 1
            if codes is not None:
                if codes[0].item() != cfg.audio_eos_code:
                    frames.append(codes)
            elif token != cfg.audio_out_token_id:
                text_ids.append(token)
                full = tokenizer.decode(text_ids, skip_special_tokens=True)
                if len(full) > len(sent_text) and full.startswith(sent_text):
                    reply({"id": rid, "text": full[len(sent_text):]})
                    sent_text = full
            if len(frames) - decoded_at >= STEP:
                decoded_at = len(frames)
                audio = np.asarray(codec.decode(mx.stack(frames, axis=-1)), dtype=np.float32).reshape(-1)
                safe = max(emitted, audio.size - HOLD * (audio.size // len(frames)))
                send_audio(rid, audio[emitted:safe], rate)
                emitted = safe
            if n % 4 == 0 and cancelled(rid):
                stop = True
                break
    if frames and not stop:
        audio = np.asarray(codec.decode(mx.stack(frames, axis=-1)), dtype=np.float32).reshape(-1)
        send_audio(rid, audio[emitted:], rate)
    reply({"id": rid, "done": True, "cancelled": stop, "prompt_tokens": int(np.asarray(input_ids).size), "generation_tokens": n})

def whole(req, prompt, images, audios):
    """Models without a slot stream (MiniCPM-o): generate the reply, then send it in one piece."""
    rid = req["id"]
    kwargs = {"max_tokens": int(req.get("max_tokens") or 512)}
    if req.get("temperature") is not None:
        kwargs["temperature"] = float(req["temperature"])
    r = generate_audio(model, processor, prompt, image=images or None, audio=audios or None, **kwargs)
    if r.text:
        reply({"id": rid, "text": r.text})
    if r.audio is not None:
        send_audio(rid, np.asarray(r.audio, dtype=np.float32).reshape(-1), int(r.sample_rate))
    reply({"id": rid, "done": True, "cancelled": False, "prompt_tokens": int(r.prompt_tokens or 0),
           "generation_tokens": int(r.generation_tokens or 0)})

reply({"ready": True})
while True:
    if pending:
        req = pending.pop(0)
    else:
        line = sys.stdin.readline()
        if not line:
            break
        if not line.strip():
            continue
        req = json.loads(line)
    if "cancel" in req:
        continue
    try:
        images = req.get("images") or []
        audios = req.get("audios") or []
        prompt = apply_chat_template(processor, model.config, with_voice_instruction(req["messages"]),
                                     num_images=len(images), num_audios=len(audios), use_tts_template=True,
                                     tools=req.get("tools") or None)
        (stream_joint if joint else whole)(req, prompt, images, audios)
    except Exception as e:
        traceback.print_exc()
        reply({"id": req.get("id"), "error": f"{type(e).__name__}: {e}"})
"""#
}
