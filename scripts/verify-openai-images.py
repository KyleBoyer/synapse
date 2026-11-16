#!/usr/bin/env python3
"""Validate Images and optional Responses image tools with the official OpenAI SDK.

Usage: python scripts/verify-openai-images.py [base_url] [image_model] [chat_model]
The optional chat model enables Responses image_generation checks.
Requires openai and pydantic, as does verify-openai-api.py.
"""
import base64
import json
import os
from pathlib import Path
import struct
import sys
import urllib.request

from openai import OpenAI
from openai.types import ImageEditStreamEvent, ImageGenStreamEvent, ImagesResponse
from openai.types.responses import Response, ResponseStreamEvent
from pydantic import TypeAdapter


def png(encoded, path):
    data = base64.b64decode(encoded, validate=True)
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "Result is not PNG"
    assert struct.unpack(">II", data[16:24]) == (256, 256), "Wrong image dimensions"
    path.write_bytes(data)


def events(base, key, body):
    request = urllib.request.Request(base + "/responses" if "tools" in body else base + "/images/generations",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(request, timeout=3600) as response:
        for raw in response:
            line = raw.decode().strip()
            if line.startswith("data:"):
                yield json.loads(line[5:].strip())


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:19000/v1"
    model = sys.argv[2] if len(sys.argv) > 2 else "flux2-klein-4b"
    chat = sys.argv[3] if len(sys.argv) > 3 else None
    key = os.environ.get("SYNAPSE_API_KEY", "unused")
    client = OpenAI(base_url=base, api_key=key, timeout=3600)
    output = Path(os.environ.get("SYNAPSE_IMAGE_OUTPUT_DIR", "build/image-checks"))
    output.mkdir(parents=True, exist_ok=True)
    request = dict(model=model, prompt="A red ceramic teapot on a wooden table, daylight, photograph.", size="256x256")
    raw = client.images.with_raw_response.generate(**request, extra_body={"seed": 42})
    result = ImagesResponse.model_validate_json(raw.text, strict=True)
    assert result.data and len(result.data) == 1
    png(result.data[0].b64_json, output / f"{model}-sdk.png")
    (output / f"{model}-generation.json").write_text(raw.text)
    print("PASS Images generation raw SDK schema and PNG", flush=True)

    adapter = TypeAdapter(ImageGenStreamEvent)
    completed = 0
    stream = list(events(base, key, {**request, "seed": 43, "stream": True, "partial_images": 1}))
    for event in stream:
        parsed = adapter.validate_python(event, strict=True)
        if parsed.type == "image_generation.completed":
            png(parsed.b64_json, output / f"{model}-stream.png")
            completed += 1
    assert completed == 1 and stream[-1]["type"] == "image_generation.completed"
    (output / f"{model}-stream.json").write_text(json.dumps(stream))
    print("PASS Images raw SSE SDK schemas and completed PNG", flush=True)

    if model.startswith("flux2") or "edit" in model:
        with (output / f"{model}-sdk.png").open("rb") as image:
            raw = client.images.with_raw_response.edit(model=model, image=image,
                prompt="Make the teapot blue. Keep the wooden table.", size="256x256")
        result = ImagesResponse.model_validate_json(raw.text, strict=True)
        assert result.data and len(result.data) == 1
        png(result.data[0].b64_json, output / f"{model}-edit-sdk.png")
        (output / f"{model}-edit.json").write_text(raw.text)
        print("PASS Images edit raw SDK schema and PNG", flush=True)

    if chat:
        request = dict(model=chat, input="Create a photograph of a red teapot on a wooden table.",
                       tools=[{"type": "image_generation", "model": model, "size": "256x256"}],
                       tool_choice={"type": "image_generation"}, max_output_tokens=256, temperature=0)
        raw = client.responses.with_raw_response.create(**request)
        result = Response.model_validate_json(raw.text, strict=True)
        calls = [item for item in result.output if item.type == "image_generation_call"]
        assert result.status == "completed" and len(calls) == 1 and calls[0].status == "completed"
        assert calls[0].revised_prompt and "teapot" in calls[0].revised_prompt.lower()
        png(calls[0].result, output / f"{model}-responses.png")
        (output / f"{model}-responses.json").write_text(raw.text)
        print("PASS Responses image tool raw SDK schema, revised prompt and PNG", flush=True)
        stream = list(events(base, key, {**request, "stream": True}))
        adapter = TypeAdapter(ResponseStreamEvent)
        for event in stream:
            adapter.validate_python(event, strict=True)
        assert stream[-1]["type"] == "response.completed"
        assert [event["sequence_number"] for event in stream] == list(range(len(stream)))
        result = Response.model_validate(stream[-1]["response"], strict=True)
        calls = [item for item in result.output if item.type == "image_generation_call"]
        assert len(calls) == 1 and calls[0].status == "completed"
        png(calls[0].result, output / f"{model}-responses-stream.png")
        (output / f"{model}-responses-stream.json").write_text(json.dumps(stream))
        print("PASS Responses image tool raw SSE SDK schemas, sequence and PNG", flush=True)


if __name__ == "__main__":
    main()
