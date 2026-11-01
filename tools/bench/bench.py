# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27", "sacrebleu>=2.4"]
# ///
"""Polylocal model benchmark.

Talks to any OpenAI-compatible server (Ollama, llama-server, mlx_lm.server),
streams each translation and records quality (chrF++, BLEU) and speed
(time-to-first-token, tokens/s).

    uv run tools/bench/bench.py --model gemma4 --label gemma4-e4b
    uv run tools/bench/bench.py --base-url http://localhost:8080/v1 --model x --template translategemma
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import sacrebleu

HERE = Path(__file__).resolve().parent

LANG_NAMES = {
    "tr": "Turkish",
    "en": "English",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
    "it": "Italian",
    "ru": "Russian",
    "ar": "Arabic",
    "zh": "Chinese",
    "ja": "Japanese",
}

DEFAULT_PAIRS = "tr-en,en-tr,tr-de,de-tr,en-de,de-en"


def build_messages(template: str, text: str, src: str, tgt: str) -> list[dict]:
    s, t = LANG_NAMES[src], LANG_NAMES[tgt]
    if template == "translategemma":
        # Prompt format from the TranslateGemma model card.
        prompt = (
            f"You are a professional {s} ({src}) to {t} ({tgt}) translator. "
            f"Your goal is to accurately convey the meaning and nuances of the original {s} text "
            f"while adhering to {t} grammar, vocabulary, and cultural sensitivities.\n"
            f"Produce only the {t} translation, without any additional explanations or commentary. "
            f"Please translate the following {s} text into {t}:\n\n\n{text}"
        )
        return [{"role": "user", "content": prompt}]
    if template == "generic":
        system = (
            f"You are a professional translator. Translate the user's text from {s} to {t}. "
            "Output only the translation. Preserve meaning, tone, numbers and formatting. "
            "Do not add explanations, quotes or notes."
        )
        return [{"role": "system", "content": system}, {"role": "user", "content": text}]
    raise ValueError(f"unknown template: {template}")


def translate(client: httpx.Client, args, text: str, src: str, tgt: str) -> dict:
    body = {
        "model": args.model,
        "messages": build_messages(args.template, text, src, tgt),
        "stream": True,
        "temperature": 0,
        "max_tokens": max(64, len(text) * 2),
        "stream_options": {"include_usage": True},
    }
    if args.no_think:
        body["reasoning_effort"] = "none"  # Ollama
        body["chat_template_kwargs"] = {"enable_thinking": False}  # llama-server / Qwen3

    start = time.perf_counter()
    ttft = None
    parts: list[str] = []
    completion_tokens = None
    with client.stream("POST", f"{args.base_url}/chat/completions", json=body) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if not line.startswith("data: "):
                continue
            data = line[6:]
            if data.strip() == "[DONE]":
                break
            chunk = json.loads(data)
            if chunk.get("usage"):
                completion_tokens = chunk["usage"].get("completion_tokens")
            for choice in chunk.get("choices", []):
                delta = choice.get("delta", {}).get("content") or ""
                if delta and ttft is None:
                    ttft = time.perf_counter() - start
                parts.append(delta)
    total = time.perf_counter() - start
    output = "".join(parts).strip()
    gen_time = total - (ttft or 0)
    tps = completion_tokens / gen_time if completion_tokens and gen_time > 0 else None
    return {"output": output, "ttft": ttft, "total": total, "tokens": completion_tokens, "tps": tps}


def ollama_memory(base_url: str, model: str) -> int | None:
    root = base_url.removesuffix("/v1")
    try:
        ps = httpx.get(f"{root}/api/ps", timeout=2).json()
    except Exception:
        return None
    for m in ps.get("models", []):
        if m.get("name", "").split(":")[0] == model.split(":")[0]:
            return m.get("size_vram") or m.get("size")
    return None


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default="http://localhost:11434/v1")
    p.add_argument("--model", required=True)
    p.add_argument("--label", help="name in reports (default: model)")
    p.add_argument("--template", choices=["generic", "translategemma"], default="generic")
    p.add_argument("--pairs", default=DEFAULT_PAIRS)
    p.add_argument("--testset", type=Path, default=HERE / "data" / "testset.jsonl")
    p.add_argument("--limit", type=int, help="only the first N items")
    p.add_argument("--no-think", action="store_true", default=True)
    p.add_argument("--think", dest="no_think", action="store_false")
    p.add_argument("--out", type=Path, default=HERE / "results")
    args = p.parse_args()
    args.base_url = args.base_url.rstrip("/")
    label = args.label or args.model

    items = [json.loads(l) for l in args.testset.read_text().splitlines() if l.strip()]
    if args.limit:
        items = items[: args.limit]
    pairs = [tuple(x.split("-")) for x in args.pairs.split(",")]

    client = httpx.Client(timeout=120)
    print(f"[{label}] warm-up…", file=sys.stderr)
    translate(client, args, "Hello.", "en", "tr")

    rows = []
    summary = {}
    for src, tgt in pairs:
        hyps, refs = [], []
        for i, item in enumerate(items, 1):
            res = translate(client, args, item[src], src, tgt)
            hyps.append(res["output"])
            refs.append(item[tgt])
            rows.append({"id": item["id"], "pair": f"{src}-{tgt}", "source": item[src], "reference": item[tgt], **res})
            print(f"\r[{label}] {src}->{tgt} {i}/{len(items)}", end="", file=sys.stderr)
        print(file=sys.stderr)
        pair_rows = [r for r in rows if r["pair"] == f"{src}-{tgt}"]
        summary[f"{src}-{tgt}"] = {
            "chrf": sacrebleu.corpus_chrf(hyps, [refs], word_order=2).score,
            "bleu": sacrebleu.corpus_bleu(hyps, [refs]).score,
            "ttft_ms": statistics.median(r["ttft"] for r in pair_rows if r["ttft"]) * 1000,
            "tps": statistics.median([r["tps"] for r in pair_rows if r["tps"]] or [0]),
        }

    result = {
        "label": label,
        "model": args.model,
        "base_url": args.base_url,
        "template": args.template,
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": len(items),
        "memory_bytes": ollama_memory(args.base_url, args.model),
        "summary": summary,
        "rows": rows,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    path = args.out / f"{label}.json"
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2))

    print(f"\n{label}  ({args.template})")
    print(f"{'pair':<7}{'chrF++':>8}{'BLEU':>7}{'TTFT ms':>9}{'tok/s':>7}")
    for pair, s in summary.items():
        print(f"{pair:<7}{s['chrf']:>8.1f}{s['bleu']:>7.1f}{s['ttft_ms']:>9.0f}{s['tps']:>7.1f}")
    print(f"\nsaved {path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path}")


if __name__ == "__main__":
    main()
