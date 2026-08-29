#!/usr/bin/env python3
"""Benchmark the watcher's vision backends against a corpus of saved frames.

The app writes that corpus: turn on "Save frames for benchmarking" in the
Watcher screen, walk a shopping trip, then pull the session directory off the
phone. Every frame lands next to the verdict the live detector gave it.

The prompt is NOT duplicated here. It is extracted from DetectionPrompt.swift at
run time so the benchmark can never drift from what the app actually sends --
if the extraction fails, this script stops rather than quietly measuring a
different prompt.

Usage:
    python3 corvus-tools/detector-bench.py FRAMES_DIR [--labels labels.json]
                                           [--models gemini-flash-lite,claude-haiku]
                                           [--limit N]

Labels file (optional; without it the script just reports what each model saw):
    {"frames/cereal-1712.jpg": {"holding": true, "item_id": "cereal"},
     "frames/frame-1713.jpg":  {"holding": false, "item_id": null}}

Environment:
    GEMINI_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY

    Read from the repo-root .env if present (copy .env.example), else from
    the shell. GOOGLE_API_KEY and GEMINI_API_KEY are interchangeable. A real
    environment variable always wins, so a one-off
    `GOOGLE_API_KEY=... python3 ...` overrides the file without editing it.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

def load_env_file() -> None:
    """Read the repo's .env into os.environ without clobbering the shell.

    Repo root first, then this directory -- one .env for the whole project is
    what the gateway and agent already expect, and a second copy is a rotation
    waiting to be half-done.

    Hand-rolled instead of python-dotenv so the script keeps its zero-dependency
    promise: it runs anywhere python3 does, with nothing to install first.
    """
    here = pathlib.Path(__file__).resolve().parent
    for path in (here.parent / ".env", here / ".env"):
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip().strip("\"'")
            # An explicitly exported variable beats the file, so a one-off
            # override on the command line does what it looks like it does.
            if key and value and key not in os.environ:
                os.environ[key] = value
        break

    # GOOGLE_API_KEY is what Google's own SDKs read; GEMINI_API_KEY is what the
    # older docs use. Accept either so a working .env is never rejected over a
    # name.
    if "GEMINI_API_KEY" not in os.environ and os.environ.get("GOOGLE_API_KEY"):
        os.environ["GEMINI_API_KEY"] = os.environ["GOOGLE_API_KEY"]


load_env_file()

REPO = pathlib.Path(__file__).resolve().parent.parent
SWIFT_PROMPT = REPO / "samples/CameraAccess/CameraAccess/Corvus/DetectionPrompt.swift"
STUDIES_DIR = REPO / "samples/CameraAccess/CameraAccess/Corvus/Studies"


# --- Canonical prompt + watchlist, read from the Swift sources -------------


def load_prompt_template() -> str:
    """Pull the prompt body out of DetectionPrompt.swift.

    Swift multi-line strings use a trailing backslash to join wrapped lines;
    undo that so the text matches byte for byte what the app sends.
    """
    src = SWIFT_PROMPT.read_text()
    match = re.search(r'return """\n(.*?)\n\s*"""', src, re.S)
    if not match:
        sys.exit(f"could not extract the prompt from {SWIFT_PROMPT}")
    body = match.group(1)
    body = re.sub(r"\\\n\s*", "", body)          # join continued lines
    body = "\n".join(line[4:] if line.startswith("    ") else line
                     for line in body.split("\n"))
    for token in ("{catalogue}", "{wearer}", "{resting}"):
        if token in body:
            sys.exit(f"prompt contains a literal {token}; extraction is confused")
    body = body.replace("\\(catalogue)", "{catalogue}")
    body = body.replace("\\(scene.wearer)", "{wearer}")
    body = body.replace("\\(scene.restingPlaces)", "{resting}")
    if "\\(" in body:
        sys.exit("prompt has an interpolation this script does not know how to "
                 "fill; teach render_prompt about it rather than guessing")
    return body


def load_study(study_id: str | None) -> dict:
    """Load a study from the same JSON files the app ships.

    One definition of the watchlist for the app and the benchmark: a study
    measured here is exactly the study that runs on the phone.
    """
    files = sorted(STUDIES_DIR.glob("*.json"))
    if not files:
        sys.exit(f"no study files in {STUDIES_DIR}")
    studies = {}
    for path in files:
        try:
            study = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            sys.exit(f"{path.name} is not valid JSON: {exc}")
        studies[study["id"]] = study
    if study_id:
        if study_id not in studies:
            sys.exit(f"unknown study {study_id!r}; have: {', '.join(sorted(studies))}")
        return studies[study_id]
    if len(studies) > 1:
        print(f"note: {len(studies)} studies available "
              f"({', '.join(sorted(studies))}); using the first. "
              f"Pass --study to choose.\n")
    return studies[sorted(studies)[0]]


GROCERY_SCENE = {
    "wearer": "a shopper in a grocery store",
    "restingPlaces": "on a shelf, in a cart, or in a basket",
}


def render_prompt(template: str, study: dict) -> str:
    """Fill the extracted template exactly as DetectionPrompt.system does."""
    catalogue = "\n".join(
        f"- {i['id']}: {i['displayName']}"
        + (f" (also called: {', '.join(i.get('aliases', []))})" if i.get("aliases") else "")
        for i in study["items"]
    )
    scene = study.get("scene") or GROCERY_SCENE
    return (template
            .replace("{catalogue}", catalogue)
            .replace("{wearer}", scene["wearer"])
            .replace("{resting}", scene["restingPlaces"]))


# --- Response parsing (mirrors DetectionParser.swift) ----------------------


def first_json_object(text: str) -> str | None:
    start = text.find("{")
    if start < 0:
        return None
    depth, in_string, escaped = 0, False, False
    for i in range(start, len(text)):
        c = text[i]
        if escaped:
            escaped = False
        elif c == "\\" and in_string:
            escaped = True
        elif c == '"':
            in_string = not in_string
        elif not in_string:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return text[start:i + 1]
    return None


def parse_detection(text: str, watchlist: list[dict]) -> dict:
    blob = first_json_object(text)
    if not blob:
        raise ValueError(f"no JSON object in: {text[:200]}")
    obj = json.loads(blob)

    raw_id = (obj.get("item_id") or "")
    raw_id = raw_id.strip() if isinstance(raw_id, str) else ""
    item_id = None
    if raw_id and raw_id.lower() not in ("null", "none"):
        by_id = {i["id"].lower(): i["id"] for i in watchlist}
        by_name = {i["displayName"].lower(): i["id"] for i in watchlist}
        item_id = by_id.get(raw_id.lower()) or by_name.get(raw_id.lower())

    return {
        "holding": bool(obj.get("holding", False)),
        "item_id": item_id,
        "product": obj.get("product"),
        "confidence": max(0.0, min(1.0, float(obj.get("confidence") or 0))),
    }


# --- Backends --------------------------------------------------------------


def post(url: str, headers: dict, payload: dict) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()[:300]}") from None


def call_gemini(model, prompt, b64):
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    data = post(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        {"Content-Type": "application/json", "x-goog-api-key": key},
        {
            "system_instruction": {"parts": [{"text": prompt}]},
            "contents": [{"role": "user", "parts": [
                {"inline_data": {"mime_type": "image/jpeg", "data": b64}},
                {"text": "Analyse this frame."},
            ]}],
            "generationConfig": {
                "temperature": 0,
                "responseMimeType": "application/json",
                "maxOutputTokens": 200,
                "thinkingConfig": {"thinkingBudget": 0},
            },
        },
    )
    return data["candidates"][0]["content"]["parts"][0]["text"]


def call_openai(model, prompt, b64):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    data = post(
        "https://api.openai.com/v1/chat/completions",
        {"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        {
            "model": model,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": [
                    {"type": "image_url",
                     "image_url": {"url": f"data:image/jpeg;base64,{b64}", "detail": "low"}},
                    {"type": "text", "text": "Analyse this frame."},
                ]},
            ],
        },
    )
    return data["choices"][0]["message"]["content"]


def call_anthropic(model, prompt, b64):
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")
    data = post(
        "https://api.anthropic.com/v1/messages",
        {"Content-Type": "application/json", "x-api-key": key,
         "anthropic-version": "2023-06-01"},
        {
            "model": model,
            "max_tokens": 200,
            "temperature": 0,
            "system": prompt,
            "messages": [{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64",
                                             "media_type": "image/jpeg", "data": b64}},
                {"type": "text", "text": "Analyse this frame."},
            ]}],
        },
    )
    return next(b["text"] for b in data["content"] if b.get("type") == "text")


# Model ids move faster than this file does -- check them against current
# provider docs before trusting a benchmark run.
BACKENDS = {
    "gemini-flash-lite": (call_gemini, "gemini-2.5-flash-lite"),
    "gemini-flash": (call_gemini, "gemini-2.5-flash"),
    "openai-mini": (call_openai, "gpt-5-mini"),
    "claude-haiku": (call_anthropic, "claude-haiku-4-5"),
}


# --- Runner ----------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames_dir", type=pathlib.Path)
    ap.add_argument("--labels", type=pathlib.Path)
    ap.add_argument("--models", default="gemini-flash-lite",
                    help=f"comma-separated; one of: {', '.join(BACKENDS)}")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--study", help="study id; defaults to the first one found")
    args = ap.parse_args()

    chosen = [m.strip() for m in args.models.split(",") if m.strip()]
    unknown = [m for m in chosen if m not in BACKENDS]
    if unknown:
        return print(f"unknown model(s): {', '.join(unknown)}") or 2

    study = load_study(args.study)
    watchlist = study["items"]
    prompt = render_prompt(load_prompt_template(), study)

    frames = sorted(p for p in args.frames_dir.rglob("*.jpg"))
    if args.limit:
        frames = frames[:args.limit]
    if not frames:
        return print(f"no .jpg frames under {args.frames_dir}") or 2

    labels = {}
    if args.labels:
        labels = json.loads(args.labels.read_text())

    print(f"study: {study['id']} ({study['name']}) -- {len(watchlist)} items")
    print(f"{len(frames)} frames, models: {', '.join(chosen)}\n")

    for model_key in chosen:
        fn, model_id = BACKENDS[model_key]
        latencies, rows, errors = [], [], 0

        for frame in frames:
            b64 = base64.b64encode(frame.read_bytes()).decode()
            started = time.monotonic()
            try:
                raw = fn(model_id, prompt, b64)
                elapsed = time.monotonic() - started
                det = parse_detection(raw, watchlist)
            except Exception as exc:  # noqa: BLE001 - report, never abort the sweep
                errors += 1
                print(f"  !! {frame.name}: {exc}")
                continue
            latencies.append(elapsed)
            rows.append((frame, det))

        print(f"--- {model_key} ({model_id}) ---")
        if not rows:
            print("  no successful calls\n")
            continue
        print(f"  calls    : {len(rows)} ok, {errors} failed")
        print(f"  latency  : p50 {statistics.median(latencies) * 1000:.0f} ms, "
              f"max {max(latencies) * 1000:.0f} ms")

        if labels:
            tp = fp = fn_ = tn = 0
            for frame, det in rows:
                key = str(frame.relative_to(args.frames_dir.parent)) \
                    if str(frame).startswith(str(args.frames_dir.parent)) else frame.name
                truth = labels.get(key) or labels.get(frame.name)
                if truth is None:
                    continue
                expected = truth.get("item_id")
                got = det["item_id"]
                if expected and got == expected:
                    tp += 1
                elif expected and got != expected:
                    fn_ += 1
                elif not expected and got:
                    fp += 1
                else:
                    tn += 1
            labelled = tp + fp + fn_ + tn
            if labelled:
                precision = tp / (tp + fp) if tp + fp else 0.0
                recall = tp / (tp + fn_) if tp + fn_ else 0.0
                print(f"  labelled : {labelled} frames")
                print(f"  precision: {precision:.2f}   (a false positive is a wrong intercept)")
                print(f"  recall   : {recall:.2f}   (a false negative is a missed one)")
                print(f"  tp {tp}  fp {fp}  fn {fn_}  tn {tn}")
        else:
            held = sum(1 for _, d in rows if d["item_id"])
            print(f"  matched  : {held}/{len(rows)} frames landed on a watchlist item")
            for frame, det in rows[:10]:
                print(f"    {frame.name}: holding={det['holding']} "
                      f"item={det['item_id']} guess={det['product']} "
                      f"conf={det['confidence']:.2f}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
