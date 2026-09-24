#!/usr/bin/env python3
"""Record objective completeness checks for the synthetic long cleanup fixture.

These checks are not a semantic/readability score. Review the generated per-record
comparisons and per-boundary excerpts separately; safe fallbacks are disclosed.
"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
WORDS = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:['’][A-Za-z]+)?")
NUMBERS = re.compile(r"[+-]?[0-9]+(?:[.,:/-][0-9]+)*")


def words(text):
    return [x.lower().replace("’", "'") for x in WORDS.findall(text)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, default=ROOT / "evals/rewrite-long-quality.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists; keep earlier evidence intact")
    fixture = json.loads(args.dataset.read_text())
    report = json.loads(args.report.read_text())
    source, output = fixture["cases"][0]["input"], report["outputText"]
    records = fixture["records"]
    markers = [row["marker"] for row in records]
    observed = re.findall(r"Record[0-9]{3}", output)
    rows = []
    for index, record in enumerate(records):
        start = output.find(record["marker"])
        end = output.find(markers[index + 1], start + 1) if index + 1 < len(records) else len(output)
        value = output[start:end] if start >= 0 and end > start else ""
        rows.append({
            "marker": record["marker"], "markerOccurrences": output.count(record["marker"]),
            "assignedEnglishWordsInOrder": words(value) == words(record["original"]),
            "exactNumericTokens": sorted(NUMBERS.findall(value)) == sorted(NUMBERS.findall(record["original"])),
            "exactLiterals": all(value.count(record[key]) == 1 for key in ["email", "url", "path"]),
            "original": record["original"], "output": value,
            "semanticAndReadabilityReview": "pending; objective checks alone do not establish quality",
        })
    boundary_rows = []
    offset = 0
    for section in report["sectionChecks"][:-1]:
        offset += len(section["original"])
        preceding_markers = list(re.finditer(r"Record[0-9]{3}", source[:offset]))
        owner_record = preceding_markers[-1].group() if preceding_markers else None
        crossing = []
        for record in records:
            for key in ["marker", "deadline", "email", "url", "path"]:
                start = source.find(record[key])
                if start < offset < start + len(record[key]):
                    crossing.append({"record": record["marker"], "kind": key, "value": record[key]})
        boundary_rows.append({"afterSection": section["section"], "characterOffset": offset,
                              "record": owner_record, "literalCrossings": crossing,
                              "sourceExcerpt": source[max(0, offset - 160):offset] + " ⟦SECTION BOUNDARY⟧ " + source[offset:offset + 160]})
    summary = {
        "scope": "Objective text-only cleanup completeness checks; not recording-duration, microphone or live hosted-relay evidence.",
        "sourceMatchesFixture": report["inputText"] == source,
        "atLeastTenSections": report["chunkCount"] >= 10,
        "sectionInputsReassembleExactly": "".join(x["original"] for x in report["sectionChecks"]) == source,
        "markersExactlyOnceInOrder": observed == markers,
        "everyRecordRetainsAssignedEnglishWordsInOrder": all(row["assignedEnglishWordsInOrder"] for row in rows),
        "everyRecordRetainsExactNumericTokens": all(row["exactNumericTokens"] for row in rows),
        "everyRecordRetainsExactLiterals": all(row["exactLiterals"] for row in rows),
        "firstAndLastRecordPresent": bool(rows[0]["output"]) and bool(rows[-1]["output"]),
        "chunkCount": report["chunkCount"], "inputCharacters": len(source), "outputCharacters": len(output),
        "fullyCleaned": report["fullyCleaned"], "guardFallbackCount": report["guardFallbackCount"],
        "providerFallbackCount": report["providerFallbackCount"], "error": report["error"],
        "elapsedSeconds": report["elapsedSeconds"], "semanticAndReadabilityReview": "pending",
    }
    result = {"summary": summary, "records": rows, "boundaries": boundary_rows}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
