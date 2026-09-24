# List formatting and cleanup evidence

The final B6 guard passed **1,015 offline checks** and **32 independent guard-audit checks**. Its [three focused provider cases](final-focused-results.json) all preserved protected facts: two cleanups were accepted and one safely returned the original after semantic rejection. The accepted outputs retained some false-start wording; this is a safety result, not a claim of perfect polishing.

The complete [47-case provider study](final-results.json) ran on B5, before B6's guard-only hardening. It retained all substantive details and met every criterion in **44/47 cases**. The **14/14 main explicit-list cases** produced separate lines; **3/5 additional shared-condition cases** did. Two Full condition cases safely fell back to raw after verifier rejection. One Light Chinese correction awkwardly produced “周二不，对，周三去测试”, preserving the final Wednesday and independent Tuesday facts but failing the intended cleanup. No provider failure occurred, and no case was selectively retried.

The suite includes 20 list/prose cases, five additional shared-condition cases and 22 cleanup-contract cases against the real GPT-6 Luna cleanup pipeline. The published 1.1.10 baseline produced separate list lines in only **1 of the same 14 cases**.

Accepted list layouts include plain bullets, unchanged existing numeric markers, and Chinese ordinal labels such as 第一/第二 or 一是/二是 on separate lines. A dash is not required when the original ordinal already labels each item. Ordinary narrative controls and a saved Full prose-only prompt stayed prose. Review criteria were set before each run.

The earlier [B1 study](b1-results.json) and [B4 study](b4-results.json) are retained. B1 met all 47 criteria and had a Full median of 1.106 seconds across 26 cases and a Light median of 0.765 seconds across 21. B4 met 46/47 criteria; one Light Chinese list lacked requested punctuation. These observations include semantic verification, but exclude recording and speech recognition. They are small samples, not a latency guarantee. Later evaluation groups ran concurrently with a separate preference review, so their durations are not a controlled speed comparison.

## Scope and revisions

These tests call the app's real text-cleanup entrypoint. They exercise provider output, local safeguards and semantic verification. They do **not** prove microphone recognition, long recording behavior or insertion into another app. The B1 arm64 debug candidate also passed 870 offline checks. Production build validation is recorded in the release report.

A1–A4 are superseded diagnostic stages. A1 exposed an inline-numbered-list failure; A2 exposed a shared condition being placed inside one bullet. The prompt and a semantic-verification guard were corrected. After A4, the user supplied a new cleanup reference, so B1 reran the tests using that final prompt core. The [supplied FreeFlow reference](https://raw.githubusercontent.com/zachlatta/freeflow/main/Sources/PostProcessingService.swift) separates cleanup from selected-text editing; no selected-text command mode was added here.

B1 predates the B2 guard extension for ordinal-only English/Chinese lines. The extension leaves these prompt files unchanged. [Five focused B2 guard cases](final-guard-results.json) all preserved shared conditions and used semantic verification; that candidate passed **877 offline checks**. Three cases deliberately use a custom style to force unbulleted ordinal lines; they test guard routing and fidelity, not preferred typography. Their observed output is included without hiding awkward label/body line breaks.

The later independent [preference review](../preference-review/README.md) exposed faithful bilingual corrections that guards rejected and a Light false-start repair that needed semantic judgment. [B3](guard-corrections-b3.json) repaired those comparison rules and passed 975 offline checks. Adversarial review then added strict final Chinese duration comparisons so an edit ratio cannot excuse 八周 becoming 九周 or losing a separate duration mention. [B4](guard-corrections-b4.json) passed 982 offline checks; accented, Cyrillic and Greek name corrections remain supported.

A bounded Light semantic check is allowed only after protected facts, literal text, languages and the ending pass, with an explicit false-start marker and a small lexical change. Quoted/code literals remain exact. B5 fixed eligibility being overwritten by a later optional comparison, added counted request introductions to Light and its native skip policy, and passed 1,003 offline checks. B6 hardens only the optional discourse-marker comparison: a retained or rephrased “one” cannot substitute for a missing real quantity. [Final B6 guard criteria, checks and source hashes](guard-corrections-b6.json) include the independent audit. The three B6 provider checks are separately labeled; B5's full study is not relabeled as B6.

## Exact prompt source hashes

SHA-256 covers each UTF-8 file, including its final newline. These files are compiled into the app through the generated defaults.

| Prompt | SHA-256 |
| --- | --- |
| `full-rewrite.txt` | `5f0ec44768bb435f737b20d2d50db6d2a0e9b2194f50496a90465c7a77753499` |
| `light-cleanup.txt` | `aa4a5955388c1080e7083e1123eb5f37d44e50dbf2ecbbc55126a01ca61e0275` |
| `punctuation.txt` | `327b25128ac05aef123514673e51bb5657c26ee1ea9a89daf9cfe66a7ee36c41` |
| `rewrite-verifier.txt` | `e4ad28ea499b70af0ceb9ed69b1e86e5f3741adc9ddbf513f5478d962f3a320e` |

[Prompt reset and instruction-boundary review](prompt-reset-review.md) confirms that saved custom styles survive updates and reset remains draft-only until Save.
