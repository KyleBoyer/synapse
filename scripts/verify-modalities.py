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


# name -> function; milestones register their sections here.
SECTIONS = {}

unknown = ONLY - SECTIONS.keys()
if unknown:
    sys.exit(f"unknown section(s): {', '.join(sorted(unknown))}; known: {', '.join(SECTIONS) or 'none yet'}")
for name, run in SECTIONS.items():
    if not ONLY or name in ONLY:
        print(f"== {name}")
        run()

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
