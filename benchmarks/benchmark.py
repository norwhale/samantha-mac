#!/usr/bin/env python3
"""
Samantha AI Benchmark Suite
Compares: Claude Haiku (solo) vs Gemma 4 31B + Claude (orchestrated)

Measures:
- Response latency (seconds)
- Response quality (scored by Claude as judge)
- Multi-agent coordination time
- Token throughput (Ollama only)

Outputs:
- benchmarks/results.json  (raw data)
- benchmarks/charts/        (PNG charts for blog/Twitter)

Usage:
  python3 benchmarks/benchmark.py           # Run all benchmarks
  python3 benchmarks/benchmark.py --chart   # Generate charts from existing results
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

# --- Config ---
ANTHROPIC_KEY = ""  # Will read from Config.xcconfig
OLLAMA_URL = "http://localhost:11434"
OLLAMA_MODEL = "gemma4:31b"
CLAUDE_MODEL = "claude-haiku-4-5-20251001"
RESULTS_FILE = Path(__file__).parent / "results.json"
CHARTS_DIR = Path(__file__).parent / "charts"

# --- Test prompts (diverse tasks) ---
TEST_PROMPTS = [
    {
        "id": "simple_greeting",
        "category": "Simple",
        "prompt": "こんにちは、今日の調子はどう？",
    },
    {
        "id": "factual_question",
        "category": "Factual",
        "prompt": "ブルガリアの首都と人口を教えてください。",
    },
    {
        "id": "coding_help",
        "category": "Technical",
        "prompt": "Pythonでフィボナッチ数列を再帰で実装する方法を簡潔に教えてください。",
    },
    {
        "id": "medical_question",
        "category": "Medical",
        "prompt": "大脳皮質の機能局在について、運動野と感覚野の違いを簡潔に説明してください。",
    },
    {
        "id": "analysis_task",
        "category": "Analysis",
        "prompt": "AIが医療に与える影響を、技術・倫理・経済の3つの観点から簡潔に分析してください。",
    },
    {
        "id": "creative_task",
        "category": "Creative",
        "prompt": "ブルガリアで医学を学ぶ日本人のショートストーリーを5文で書いてください。",
    },
    {
        "id": "reasoning_task",
        "category": "Reasoning",
        "prompt": "もし人間の寿命が200歳になったら、医療制度はどう変わるべきか、論理的に考えてください。",
    },
]


def load_api_key():
    """Read Anthropic API key from Config.xcconfig."""
    global ANTHROPIC_KEY
    config_path = Path(__file__).parent.parent / "Config.xcconfig"
    if config_path.exists():
        for line in config_path.read_text().splitlines():
            if line.startswith("ANTHROPIC_API_KEY"):
                ANTHROPIC_KEY = line.split("=", 1)[1].strip()
                return
    print("WARNING: Could not load API key from Config.xcconfig")


def check_ollama():
    """Check if Ollama is running and model is available."""
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/tags")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            models = [m["name"] for m in data.get("models", [])]
            return any("gemma4" in m for m in models)
    except Exception:
        return False


def call_claude(prompt, system="簡潔に日本語で回答してください。"):
    """Call Claude Haiku API and return (response_text, latency_seconds)."""
    body = json.dumps({
        "model": CLAUDE_MODEL,
        "max_tokens": 512,
        "system": system,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": ANTHROPIC_KEY,
            "anthropic-version": "2023-06-01",
        },
    )

    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            text = data["content"][0]["text"]
            latency = time.time() - start
            return text, latency
    except Exception as e:
        return f"(error: {e})", time.time() - start


def call_ollama(prompt, system="簡潔に日本語で回答してください。"):
    """Call local Ollama (Gemma 4 31B) and return (response_text, latency_seconds, tokens_per_sec)."""
    body = json.dumps({
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "system": system,
        "stream": False,
        "options": {"temperature": 0.7, "num_predict": 512},
    }).encode()

    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
    )

    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
            text = data.get("response", "")
            latency = time.time() - start
            eval_count = data.get("eval_count", 0)
            eval_duration = data.get("eval_duration", 1)
            tps = eval_count / (eval_duration / 1e9) if eval_duration > 0 else 0
            return text, latency, tps
    except Exception as e:
        return f"(error: {e})", time.time() - start, 0


def call_orchestrated(prompt):
    """Simulate orchestrated flow: Gemma decides → delegates to Claude or answers directly."""
    # Step 1: Gemma orchestrates
    orch_system = (
        "Analyze this request. Reply with ONLY one word: "
        "'direct' if you can answer it, 'delegate' if it needs tools or specialist knowledge."
    )
    decision, orch_latency, _ = call_ollama(prompt, system=orch_system)

    # Step 2: Based on decision
    if "delegate" in decision.lower():
        # Gemma delegates to Claude
        claude_text, claude_latency = call_claude(prompt)
        total_latency = orch_latency + claude_latency
        return claude_text, total_latency, "delegated_to_claude"
    else:
        # Gemma answers directly
        text, latency, tps = call_ollama(prompt)
        return text, latency, "gemma_direct"


def score_quality(prompt, response):
    """Use Claude as a judge to score response quality (1-10)."""
    judge_prompt = f"""以下の質問と回答を評価してください。
1〜10のスコアのみを数字だけで返してください。
評価基準: 正確性、有用性、簡潔さ、日本語の自然さ

質問: {prompt}
回答: {response[:500]}

スコア:"""

    score_text, _ = call_claude(judge_prompt, system="あなたは回答品質の評価者です。スコア（1-10の数字）だけを返してください。")
    try:
        # Extract first number from response
        import re
        nums = re.findall(r'\d+', score_text)
        return min(int(nums[0]), 10) if nums else 5
    except Exception:
        return 5


def run_benchmarks():
    """Run all benchmarks and save results."""
    load_api_key()
    ollama_available = check_ollama()

    print(f"\n{'='*60}")
    print(f"  Samantha AI Benchmark Suite")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"  Claude: {CLAUDE_MODEL}")
    print(f"  Ollama: {'✅ ' + OLLAMA_MODEL if ollama_available else '❌ Not available'}")
    print(f"{'='*60}\n")

    results = {
        "timestamp": datetime.now().isoformat(),
        "claude_model": CLAUDE_MODEL,
        "ollama_model": OLLAMA_MODEL if ollama_available else None,
        "ollama_available": ollama_available,
        "tests": [],
    }

    for i, test in enumerate(TEST_PROMPTS):
        print(f"[{i+1}/{len(TEST_PROMPTS)}] {test['category']}: {test['prompt'][:40]}…")

        result = {"id": test["id"], "category": test["category"], "prompt": test["prompt"]}

        # Claude solo
        print("  Claude solo…", end="", flush=True)
        claude_text, claude_lat = call_claude(test["prompt"])
        claude_score = score_quality(test["prompt"], claude_text)
        result["claude_solo"] = {
            "latency": round(claude_lat, 2),
            "quality_score": claude_score,
            "response_length": len(claude_text),
        }
        print(f" {claude_lat:.1f}s, score={claude_score}")

        # Ollama solo (if available)
        if ollama_available:
            print("  Gemma solo…", end="", flush=True)
            gemma_text, gemma_lat, gemma_tps = call_ollama(test["prompt"])
            gemma_score = score_quality(test["prompt"], gemma_text)
            result["gemma_solo"] = {
                "latency": round(gemma_lat, 2),
                "quality_score": gemma_score,
                "response_length": len(gemma_text),
                "tokens_per_sec": round(gemma_tps, 1),
            }
            print(f" {gemma_lat:.1f}s, score={gemma_score}, {gemma_tps:.1f} tok/s")

            # Orchestrated (Gemma + Claude)
            print("  Orchestrated…", end="", flush=True)
            orch_text, orch_lat, orch_path = call_orchestrated(test["prompt"])
            orch_score = score_quality(test["prompt"], orch_text)
            result["orchestrated"] = {
                "latency": round(orch_lat, 2),
                "quality_score": orch_score,
                "response_length": len(orch_text),
                "path": orch_path,
            }
            print(f" {orch_lat:.1f}s, score={orch_score}, path={orch_path}")

        results["tests"].append(result)
        print()

    # Save results
    RESULTS_FILE.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f"\n✅ Results saved to {RESULTS_FILE}")

    # Print summary
    print_summary(results)

    # Generate charts
    generate_charts(results)

    return results


def print_summary(results):
    """Print a summary table."""
    tests = results["tests"]

    print(f"\n{'='*60}")
    print("  SUMMARY")
    print(f"{'='*60}")

    # Claude averages
    c_lats = [t["claude_solo"]["latency"] for t in tests]
    c_scores = [t["claude_solo"]["quality_score"] for t in tests]
    print(f"\n  Claude Haiku (solo):")
    print(f"    Avg latency:  {sum(c_lats)/len(c_lats):.1f}s")
    print(f"    Avg quality:  {sum(c_scores)/len(c_scores):.1f}/10")

    if results["ollama_available"]:
        # Gemma averages
        g_lats = [t["gemma_solo"]["latency"] for t in tests]
        g_scores = [t["gemma_solo"]["quality_score"] for t in tests]
        g_tps = [t["gemma_solo"]["tokens_per_sec"] for t in tests]
        print(f"\n  Gemma 4 31B (solo, local):")
        print(f"    Avg latency:  {sum(g_lats)/len(g_lats):.1f}s")
        print(f"    Avg quality:  {sum(g_scores)/len(g_scores):.1f}/10")
        print(f"    Avg tok/s:    {sum(g_tps)/len(g_tps):.1f}")

        # Orchestrated averages
        o_lats = [t["orchestrated"]["latency"] for t in tests]
        o_scores = [t["orchestrated"]["quality_score"] for t in tests]
        print(f"\n  Orchestrated (Gemma + Claude):")
        print(f"    Avg latency:  {sum(o_lats)/len(o_lats):.1f}s")
        print(f"    Avg quality:  {sum(o_scores)/len(o_scores):.1f}/10")

    print(f"\n{'='*60}\n")


def generate_charts(results=None):
    """Generate comparison charts as PNG files."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.font_manager as fm

    # Try to use a Japanese font
    jp_fonts = [f.name for f in fm.fontManager.ttflist if "Hiragino" in f.name or "Gothic" in f.name]
    if jp_fonts:
        plt.rcParams["font.family"] = jp_fonts[0]
    plt.rcParams["font.size"] = 12

    if results is None:
        if not RESULTS_FILE.exists():
            print("No results file found. Run benchmarks first.")
            return
        results = json.loads(RESULTS_FILE.read_text())

    CHARTS_DIR.mkdir(exist_ok=True)
    tests = results["tests"]
    has_ollama = results["ollama_available"]

    categories = [t["category"] for t in tests]

    # --- Chart 1: Latency Comparison ---
    fig, ax = plt.subplots(figsize=(12, 6))
    x = range(len(categories))
    width = 0.25

    claude_lats = [t["claude_solo"]["latency"] for t in tests]
    bars1 = ax.bar([i - width for i in x], claude_lats, width, label="Claude Haiku (Cloud)", color="#8B5CF6")

    if has_ollama:
        gemma_lats = [t["gemma_solo"]["latency"] for t in tests]
        orch_lats = [t["orchestrated"]["latency"] for t in tests]
        bars2 = ax.bar(list(x), gemma_lats, width, label="Gemma 4 31B (Local)", color="#06B6D4")
        bars3 = ax.bar([i + width for i in x], orch_lats, width, label="Orchestrated (Gemma+Claude)", color="#F59E0B")

    ax.set_xlabel("Task Category")
    ax.set_ylabel("Latency (seconds)")
    ax.set_title("Samantha AI — Response Latency Comparison")
    ax.set_xticks(list(x))
    ax.set_xticklabels(categories, rotation=30, ha="right")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(CHARTS_DIR / "latency_comparison.png", dpi=150, facecolor="white")
    print(f"📊 Saved: {CHARTS_DIR / 'latency_comparison.png'}")
    plt.close()

    # --- Chart 2: Quality Scores ---
    fig, ax = plt.subplots(figsize=(12, 6))

    claude_scores = [t["claude_solo"]["quality_score"] for t in tests]
    ax.bar([i - width for i in x], claude_scores, width, label="Claude Haiku", color="#8B5CF6")

    if has_ollama:
        gemma_scores = [t["gemma_solo"]["quality_score"] for t in tests]
        orch_scores = [t["orchestrated"]["quality_score"] for t in tests]
        ax.bar(list(x), gemma_scores, width, label="Gemma 4 31B", color="#06B6D4")
        ax.bar([i + width for i in x], orch_scores, width, label="Orchestrated", color="#F59E0B")

    ax.set_xlabel("Task Category")
    ax.set_ylabel("Quality Score (1-10)")
    ax.set_title("Samantha AI — Response Quality Comparison (Claude as Judge)")
    ax.set_xticks(list(x))
    ax.set_xticklabels(categories, rotation=30, ha="right")
    ax.set_ylim(0, 11)
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(CHARTS_DIR / "quality_comparison.png", dpi=150, facecolor="white")
    print(f"📊 Saved: {CHARTS_DIR / 'quality_comparison.png'}")
    plt.close()

    # --- Chart 3: Radar chart (overall comparison) ---
    if has_ollama:
        fig, ax = plt.subplots(figsize=(8, 8), subplot_kw=dict(projection="polar"))

        metrics = ["Avg Latency\n(inverse)", "Avg Quality", "Simple Tasks", "Analysis Tasks", "Creative Tasks"]
        n = len(metrics)
        angles = [i * 2 * 3.14159 / n for i in range(n)]
        angles.append(angles[0])

        def get_radar_values(key):
            lats = [t[key]["latency"] for t in tests]
            scores = [t[key]["quality_score"] for t in tests]
            simple = [t[key]["quality_score"] for t in tests if t["category"] == "Simple"][0]
            analysis = [t[key]["quality_score"] for t in tests if t["category"] == "Analysis"][0]
            creative = [t[key]["quality_score"] for t in tests if t["category"] == "Creative"][0]
            avg_lat = 10 - min(sum(lats)/len(lats), 10)  # Inverse: lower latency = higher score
            avg_q = sum(scores)/len(scores)
            return [avg_lat, avg_q, simple, analysis, creative]

        for key, label, color in [
            ("claude_solo", "Claude Haiku", "#8B5CF6"),
            ("gemma_solo", "Gemma 4 31B", "#06B6D4"),
            ("orchestrated", "Orchestrated", "#F59E0B"),
        ]:
            vals = get_radar_values(key)
            vals.append(vals[0])
            ax.plot(angles, vals, "o-", linewidth=2, label=label, color=color)
            ax.fill(angles, vals, alpha=0.1, color=color)

        ax.set_xticks(angles[:-1])
        ax.set_xticklabels(metrics, size=10)
        ax.set_ylim(0, 10)
        ax.set_title("Samantha AI — Overall Comparison", pad=20)
        ax.legend(loc="upper right", bbox_to_anchor=(1.3, 1.1))
        fig.tight_layout()
        fig.savefig(CHARTS_DIR / "radar_comparison.png", dpi=150, facecolor="white")
        print(f"📊 Saved: {CHARTS_DIR / 'radar_comparison.png'}")
        plt.close()

    # --- Chart 4: Tokens per second (Ollama only) ---
    if has_ollama:
        fig, ax = plt.subplots(figsize=(10, 5))
        tps_values = [t["gemma_solo"]["tokens_per_sec"] for t in tests]
        bars = ax.bar(categories, tps_values, color="#06B6D4", edgecolor="white")
        for bar, val in zip(bars, tps_values):
            ax.text(bar.get_x() + bar.get_width()/2., bar.get_height() + 0.3,
                    f"{val:.1f}", ha="center", va="bottom", fontsize=10)
        ax.set_xlabel("Task Category")
        ax.set_ylabel("Tokens / Second")
        ax.set_title("Gemma 4 31B on M3 Max — Token Throughput")
        ax.grid(axis="y", alpha=0.3)
        plt.xticks(rotation=30, ha="right")
        fig.tight_layout()
        fig.savefig(CHARTS_DIR / "gemma_throughput.png", dpi=150, facecolor="white")
        print(f"📊 Saved: {CHARTS_DIR / 'gemma_throughput.png'}")
        plt.close()

    print(f"\n✅ All charts saved to {CHARTS_DIR}/")


if __name__ == "__main__":
    if "--chart" in sys.argv:
        generate_charts()
    else:
        run_benchmarks()
