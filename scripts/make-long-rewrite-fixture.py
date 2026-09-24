#!/usr/bin/env python3
"""Generate deterministic synthetic long cleanup text; no user content or API calls."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
owners = ["Mira", "Jonah", "Sofia", "Elias", "Nora", "Mateo", "Iris", "Leon", "Nina", "Theo", "Zara", "Owen"]
days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
paragraphs = []
records = []
for index in range(1, 73):
    marker = f"Record{index:03}"
    owner, reviewer = owners[(index - 1) % len(owners)], owners[index % len(owners)]
    deadline = f"{days[(index - 1) % len(days)]} {9 + index % 8:02}:{index % 60:02}"
    count = str(10 + index)
    address = f"Case{index:03}+notes@Example.com"
    url = f"https://example.com/review/{index:03}?mode=preview"
    path = f"/tmp/case{index:03}/notes.json"
    prose = (
        f"{marker} 这一项由 {owner} 负责检查 {count} 个测试结果然后请 {reviewer} 复核 "
        f"deadline {deadline} 这个时间只是计划如果测试失败就不要发布也不要把它写成已经完成 "
        f"请把结论发到 {address} 并保留原始附件这个邮箱的大小写不要改 "
        f"相关记录在 {url} 路径是 {path} 只读检查不要覆盖文件 "
        "我们需要区分已经确认的问题和仍然不确定的推测先记录实际观察再讨论可能的原因 "
        "如果复核人没有确认请保留待确认状态不要自动替对方同意也不要把这个条件移到别的事项上 "
        "旧版本需要继续保留因为我们可能还要比较结果这不是删除旧文件的授权 "
        f"最后请 {owner} 回复 {reviewer} 说明本项还有哪些问题没有解决这项工作与下一项分别跟进\n\n"
    )
    records.append({"marker": marker, "owner": owner, "reviewer": reviewer, "count": count,
                    "deadline": deadline, "email": address, "url": url, "path": path,
                    "original": prose})
    paragraphs.append(prose)
text = "".join(paragraphs)
literal_values = [record[key] for record in records for key in ["marker", "email", "url", "path"]]
dataset = {
    "schemaVersion": 1,
    "status": "Predeclared deterministic synthetic long cleanup fixture; no microphone/audio/hosted-service coverage.",
    "protocol": {"runsPerMode": 1, "retryPolicy": "No selective retries. Record every per-section proposal and fallback.",
                 "minimumSections": 10,
                 "scope": "Text-only real Luna cleanup, independent guards and cross-section reassembly; not recording-duration proof."},
    "records": records,
    "cases": [{
        "id": "long-mixed-completeness", "split": "evaluation", "languages": ["zh-Hans", "en"],
        "context": {}, "input": text, "preserveExactly": literal_values,
        "acceptanceCriteria": [
            "At least 10 actual cleanup sections, with recorded source boundaries and one request per section; no retry loop.",
            "All 72 unique record markers occur once in original order; every record retains its assigned owner, reviewer, exact count and deadline.",
            "Every email, URL and path remains byte-for-byte identical; every numeric token retains its spelling and multiplicity.",
            "Keep the planned-versus-completed distinction, conditional no-release, no-overwrite/no-delete instructions, pending confirmation, uncertainty, and unresolved questions in every record.",
            "Preserve ordered English words and all Chinese/English language switches; do not move a condition into an adjacent record.",
            "Keep the first and final record complete and inspect records crossing each section boundary.",
            "Review Chinese punctuation and paragraph readability separately from guard acceptance; count safe raw fallbacks as incomplete polish, not quality passes."
        ]
    }]
}
output = ROOT / "evals/rewrite-long-quality.json"
output.write_text(json.dumps(dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Generated {output.relative_to(ROOT)}: {len(text)} characters, {len(records)} records.")
