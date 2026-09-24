#!/usr/bin/env python3
"""Evaluate fixed synthetic transcripts through an immutable app's real cleanup CLI.

Dry-run by default. --execute uses the app's saved OpenAI key internally; this script
never reads credentials or writes persistent preferences. No audio is recorded or sent.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, default=ROOT / "evals/rewrite-quality.json")
    parser.add_argument("--split", choices=["development", "evaluation", "holdout", "all"], default="evaluation")
    parser.add_argument("--modes", default="full,light", help="full, light, or full,light; None is tested in the controller suite")
    parser.add_argument("--limit", type=int, default=6, help="Maximum cases; 0 explicitly selects all in the split")
    parser.add_argument("--case-timeout", type=int, default=90, help="External per-case deadline in seconds (1–600); use an explicit longer bound for multi-section fixtures")
    parser.add_argument("--execute", action="store_true", help="Run real provider requests; otherwise save the plan only")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be empty so earlier runs cannot be overwritten")
    modes = args.modes.split(",")
    if not modes or any(mode not in {"full", "light"} for mode in modes) or len(set(modes)) != len(modes):
        parser.error("modes must be full, light, or full,light")
    if args.limit < 0:
        parser.error("limit cannot be negative")
    if not 1 <= args.case_timeout <= 600:
        parser.error("case-timeout must be between 1 and 600 seconds")
    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))
    cases = [case for case in dataset["cases"] if args.split == "all" or case["split"] == args.split]
    if args.limit:
        cases = cases[:args.limit]
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "startedAt": now(), "binary": str(binary), "binarySHA256": digest(binary),
        "dataset": str(args.dataset.resolve()), "datasetSHA256": digest(args.dataset),
        "executionRequested": args.execute, "source": "synthetic text only",
        "externalCaseTimeoutSeconds": args.case_timeout,
        "persistentPreferencesWritten": False, "microphoneUsed": False,
        "limitations": [
            "CLI exercises the cleanup stage, including independent validation; it is not an end-to-end recording/insertion test.",
            "Light requests the model here even when the app's cleanup policy could skip it; policy has separate offline tests.",
            "None and preceding-text contexts are not supported by this CLI and must be tested in the controller suite.",
            "Automatic checks do not score full semantic fidelity or readability; case acceptance criteria require review.",
        ], "cases": [],
    }
    consecutive_errors = 0
    for case in cases:
        for mode in modes:
            name = case["id"] + "-" + mode
            entry = {"id": name, "caseID": case["id"], "mode": mode,
                     "acceptanceCriteria": case["acceptanceCriteria"], "context": case["context"]}
            manifest["cases"].append(entry)
            if case["context"].get("precedingText"):
                entry["skipped"] = "CLI cannot supply preceding text; no request made"
                continue
            if consecutive_errors >= 3:
                entry["skipped"] = "Stopped after three consecutive execution/provider errors; no request made"
                continue
            if digest(binary) != manifest["binarySHA256"]:
                entry["skipped"] = "Binary changed during evaluation; no request made"
                write(output / "manifest.json", manifest)
                return 1
            transcript = output / (name + ".txt")
            report = output / (name + ".json")
            transcript.write_text(case["input"], encoding="utf-8")
            arguments = [
                str(binary), "--cleanup-file", str(transcript), "--report", str(report),
                "-usesHostedService", "NO", "-dictationMode", "rewrite" if mode == "full" else "clean",
                "-cleanupModel", "gpt-6-luna", "-openAIBaseURL", "https://api.openai.com",
                "-customInstructions", "", "-dictionaryText", "", "-replacementsText", "",
                "-rewritePromptOverride", case["context"].get("rewritePromptOverride", ""),
                "-chineseVariant", "traditional" if "zh-Hant" in case["languages"] else "simplified",
                "-allowFormatting", "NO", "-spokenCommands", "NO", "-cjkSpacing", "YES",
                "-skipLLMForShort", "NO", "-skipLLMWhenClean", "NO", "-compactPrompt", "YES",
                "-skipVerifierWhenVerbatim", "YES", "-openAIPriorityTier", "NO",
                "-guardStrictness", "normal", "-llmTimeout", "30",
            ]
            entry.update({"arguments": arguments[1:], "inputSHA256": digest(transcript)})
            if not args.execute:
                entry["status"] = "planned; no provider request"
                continue
            entry["startedAt"] = now()
            started = time.monotonic()
            try:
                result = subprocess.run(arguments, capture_output=True, text=True, timeout=args.case_timeout)
                (output / (name + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
                entry["exitCode"] = result.returncode
                if report.exists():
                    evidence = json.loads(report.read_text(encoding="utf-8"))
                    text = evidence["outputText"]
                    entry.update({
                        "report": report.name, "fullyCleaned": evidence["fullyCleaned"],
                        "guardFallbackCount": evidence["guardFallbackCount"],
                        "providerFallbackCount": evidence["providerFallbackCount"],
                        "error": evidence["error"],
                        "originalRetainedExactly": text.encode() == case["input"].encode(),
                        "requiredLiteralsPresent": all(value in text for value in case["preserveExactly"]),
                        "numericSpellingsPreserved": sorted(re.findall(r"[+-]?[0-9]+(?:[.,:/-][0-9]+)*", text)) == sorted(re.findall(r"[+-]?[0-9]+(?:[.,:/-][0-9]+)*", case["input"])),
                        "manualQualityReview": "pending; compare against case acceptance criteria",
                    })
                    consecutive_errors = consecutive_errors + 1 if evidence["error"] or result.returncode else 0
                else:
                    entry["error"] = "CLI did not produce a report"
                    consecutive_errors += 1
            except subprocess.TimeoutExpired as error:
                captured = (error.stdout or b"") + (error.stderr or b"")
                (output / (name + ".log")).write_bytes(captured if isinstance(captured, bytes) else captured.encode())
                entry["error"] = f"Harness external {args.case_timeout}-second deadline exceeded; no retry (not an app/provider timeout)"
                consecutive_errors += 1
            entry["elapsedSeconds"] = time.monotonic() - started
            write(output / "manifest.json", manifest)
            print(json.dumps({"id": name, "fullyCleaned": entry.get("fullyCleaned"), "guardFallbacks": entry.get("guardFallbackCount"), "error": entry.get("error")}), flush=True)
    manifest.update({"finishedAt": now(), "binarySHA256After": digest(binary),
                     "binaryUnchanged": digest(binary) == manifest["binarySHA256"]})
    write(output / "manifest.json", manifest)
    print(f"Evidence saved: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
