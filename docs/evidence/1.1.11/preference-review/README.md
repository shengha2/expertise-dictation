# Preference review — B5 complete paired evaluation

**All 24 delivered outputs preserved factual meaning.** Light now handles the bilingual corrections, counted two-item request and long-email formatting that earlier runs missed. Three protective fallbacks occurred: two kept exact quote/code text and one prevented Full from dropping a budget/scope clarification. No provider errors or provider fallbacks occurred.

**Two Full outputs still missed an editing goal:** the protected correction case stayed raw, and one Traditional Chinese two-topic message stayed a paragraph instead of a list. Both remain factually correct. The longer email is substantially easier to read in Full, but greeting/closing polish is still imperfect. These limitations are retained, not retried away.

This is **Codex model-based qualitative judgment**, not a human study or blinded preference vote. Twelve realistic synthetic scenarios and a rubric were defined before B2. B2, B4 and B5 each ran the full 24-case matrix once; no selective retries occurred. The original input is a raw reference, not another model request.

## What was preferable

Full was preferred alone in **2 cases**, Light alone in **2**, they tied in **5**, and both tied with raw in **3**. Appropriate no-op results preserve text that was already clear. These are judgments on a small purpose-built sample, not a universal ranking of modes.

| Case | Full / Light / raw scores¹ | Preferred displayed text | Assessment |
| --- | --- | --- | --- |
| handoff-two-asks | 5,5,5,5,5 / 5,5,4,5,5 / 5,5,4,3,5 | Full | Full pass; Light pass |
| bilingual-update-two-areas | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,5,3,5 | Full = Light | Full pass; Light pass |
| shared-condition-and-exception | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,4,3,5 | Full = Light | Full pass; Light pass |
| chinese-quotes-code | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,5,5,5 | Full = Light = Raw | Full pass; Light pass |
| mixed-self-correction | 5,5,3,4,5 / 5,5,5,5,5 / 5,5,3,4,5 | Light | Full miss; Light pass |
| unresolved-people-and-times | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,4,5,5 | Full = Light | Full pass; Light pass |
| spelled-email-and-name | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,3,4,5 | Full = Light | Full pass; Light pass |
| deliberate-emotion-and-repetition | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,5,5,5 | Full = Light = Raw | Full pass; Light pass |
| narrative-not-a-checklist | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,4,5,5 | Full = Light | Full pass; Light pass |
| dictated-email-request-not-execution | 5,5,5,5,5 / 5,5,5,5,5 / 5,5,5,5,5 | Full = Light = Raw | Full pass; Light pass |
| rambling-project-email | 5,5,5,4,5 / 5,5,4,3,5 / 5,5,3,2,5 | Full | Full partial; Light partial |
| traditional-chinese-shared-choice | 5,5,5,3,5 / 5,5,5,5,5 / 5,5,5,3,5 | Light | Full miss; Light pass |

¹ Scores are **fidelity, voice/tone, fluency, structure, restraint**, each 1–5. Fidelity is a hard gate: style never offsets a lost claim or condition. Abandoned explicit self-correction wording is not an independent fact, but independent mentions and scope restrictions are. Scores judge delivered text, not a rejected proposal.

## Before and after

- **B2:** three cleanup misses: both bilingual correction outputs and Light long-email structure. Two additional fallbacks correctly protected quotes.
- **B4:** Light bilingual correction improved; Full correction and Light long-email structure remained uncleaned. Light also missed a counted two-item list. Its Full emotion safeguard correctly preserved deliberate emphasis.
- **B5:** Light succeeds on those correction, counted-list and long-email cases. Full still falls back when its proposal removes the budget/scope clarification; this is correct protection with an unmet editing goal. One Full Traditional Chinese list remains prose despite a clear two-topic introduction.
- Proposals vary between requests. Output differences cannot all be assigned to guard changes. No remaining miss was selectively retried.

## Case-by-case judgment

**handoff-two-asks** — Both now produce the two distinct list items and preserve the separate-file instruction outside the list. Full has a small polish advantage through complete-sentence capitalization and punctuation. Light's lowercase fragments are still usable and the B4 no-list miss is absent.

**bilingual-update-two-areas** — Both preserve the login and billing qualifications, mixed languages and warning against claiming a decided price increase. Extra blank-line spacing in Light does not change readability enough to justify a preference.

**shared-condition-and-exception** — Both keep both prerequisites outside all three items, plus the do-nothing exception and unchanged outside group. Full uses complete sentences; Light uses a semicolon-linked list. Both preserve all action owners, exclusions and duration.

**chinese-quotes-code** — Both outputs equal the already-good original, preserving exact code and quoted wording. The rejected proposals add punctuation inside a protected quote. Keeping the original is preferable and is an appropriate safeguard rather than a quality failure.

**mixed-self-correction** — Light correctly keeps eight weeks and Wednesday afternoon while preserving the independent Tuesday mention and the scope/budget clarification. Full safely keeps the raw transcript: its proposed rewrite deletes the entire clarification that only duration was being corrected, not the budget. Rejecting that deletion is correct. The delivered Full text still has abandoned wording and correction markers, so it does not meet the cleanup goal. No guard weakening is warranted.

**unresolved-people-and-times** — Both preserve the possible owners, no-change option, alternative dates, customer dependency and undecided tone. Full slightly smooths the Chinese date clause; both punctuate For now naturally. No decision or checklist is invented.

**spelled-email-and-name** — Both produce joan@example.com and keep the spelling clarification, Renée, Anaïs, exact subject and draft/final restrictions. Both retain the question rather than performing the requested action. The displayed text is identical.

**deliberate-emotion-and-repetition** — Both return the original directly in this run. Deliberate repetition, frustration, profanity and the rollback demand remain intact. Unlike B4, no fallback is needed; the user-visible result is the same correct, restrained no-op.

**narrative-not-a-checklist** — Both preserve the diagnostic chronology as prose and startup as an untested guess. The comma after the third-try phrase helps reading; the extra At first comma in Full is optional. Neither manufactures troubleshooting instructions.

**dictated-email-request-not-execution** — All displayed alternatives correctly preserve the email-writing request as text. No draft, greeting, meeting confirmation, answer or sending decision is invented. An unchanged result is appropriate.

**rambling-project-email** — Both now remove false starts, preserve every substantive qualification and show all three demo checks as separate items. Light's proposal is accepted through its bounded false-start check, fixing the B2/B4 false rejection. Full better separates the dictionary and closing topics; Light leaves denser surrounding paragraphs and conjunction punctuation in its list. Both keep the greeting and closing inline, so neither receives perfect email-structure marks. Full is preferred for scanability.

**traditional-chinese-shared-choice** — Light produces the two requested points with all conditions and Traditional Chinese intact. Full instead returns the original paragraph, with no safeguard fallback. Meaning and tone remain correct, but Full misses the explicit two-topic list layout. This stochastic formatting miss is retained and disclosed rather than selectively retried.

## Timing and reproducibility

Full median cleanup time was **1.165 s** (range 0.880–2.956 s). Light median was **1.189 s** (range 0.951–2.908 s). These times include validation but exclude recording, speech recognition and insertion. This small sample is not a speed guarantee.

[Predeclared fixtures and rubric](fixtures.json) · [Complete B5 review and all outputs](review-b5.json) · [Historical B4 review and all outputs](review-b4.json) · [Historical B2 review and all outputs](review-b2.json). Each JSON is self-contained. Unedited manifests/logs are retained locally; they are not needed to read these public records.

B5 binary SHA-256: `f8384f0e27681c1a2d71bb7a58211922fcfa4bf3575d530b71f30c073085b808`. Exact relevant source/prompt hashes are recorded in the B5 JSON. This is the tested arm64 cleanup candidate, not the final universal DMG. Subsequent guard-only hardening is validated separately; these 24 outputs remain scoped to B5 and must not be described as a complete later-candidate rerun.

The supplied [FreeFlow reference](https://raw.githubusercontent.com/zachlatta/freeflow/main/Sources/PostProcessingService.swift) informed restrained cleanup and instruction preservation; the user additionally requested actual list formatting. No competitor output is claimed.

The raw control is unchanged input, not a new native No rewrite test. The CLI requests Light cleanup even when native policy could skip it. This evaluation does not test microphone recognition, physical shortcuts, long recording durability, list rendering in destination apps, copying or insertion.
