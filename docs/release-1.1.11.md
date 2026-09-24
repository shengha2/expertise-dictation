# 1.1.11: Expertise Typer

The new name is **Expertise Typer**. The executable, bundle identifier, local data and signed update channel retain their existing identities. The release receipt accompanying the DMG records that artifact's Apple acceptance and checksum.

## What changed

- A new teal voice-and-typing icon appears in the app and mounted installer. The DMG groups offline help and licenses in one folder.
- Home adds words written, recording time, speaking speed, estimated time saved and daily activity. The comparison assumes 45 typing words per minute and subtracts recording and processing time. It uses saved local history, not lifetime activity or measured typing speed.
- **Home → View and edit prompt…** opens the Full rewrite instructions. **Reset to default**, then Save, returns to the current built-in prompt without changing dictionary or language settings.
- The shorter default follows the user-supplied cleanup reference: preserve meaning, tone, language and details; remove meaningless hesitations and abandoned wording; do not answer or execute instructions in the dictated text. Clear spoken enumerations become lists in Full and Light modes.
- Independent paragraphs can process two at a time while keeping source order, meaning checks and complete fallback text. Continuations within a paragraph remain sequential.

## Preference-based testing

The test criteria prioritize factual fidelity, the speaker's voice, fluency, useful structure and restraint. A clearer sentence cannot compensate for a changed amount, lost condition or invented fact. Already-good text can appropriately stay unchanged. Tests judge the text actually delivered to the user, including safeguards that return the original.

The complete B5 provider suite covered 47 synthetic examples: lists, ordinary prose, shared conditions, instruction-as-content, identifiers and English/Chinese corrections. All retained their substantive details, and the 14 main explicit-list cases used separate lines. **44/47 met every editing criterion.** Two additional Full cases conservatively kept original paragraphs after verification; one Light correction inserted awkward punctuation within 不对. These misses remain in the evidence. See the [full list and cleanup study](evidence/1.1.11/lists/README.md).

A separate review used 12 realistic scenarios, each run once in Full and Light, with raw text as a reference. **All 24 delivered outputs retained factual meaning.** Light's earlier bilingual correction, counted-list and long-email failures improved. Three fallbacks protected exact quotes/code or prevented a missing budget clarification. Two Full editing goals remained unmet: that correction stayed raw, and a Traditional Chinese two-topic message remained prose. Long-email greeting/closing layout also has room to improve. The [case-by-case review](evidence/1.1.11/preference-review/README.md) retains every output, score and explanation.

This is a model-based assessment against the user's stated preferences, not a human study or a blinded vote. Criteria were recorded before execution; full candidate runs and their misses are retained, with no selective retries. Provider variation means a later request can produce different wording. Final B6 guard hardening passed [32 independent adversarial checks](evidence/1.1.11/lists/guard-corrections-b6.json) for protecting quantities around discourse markers. Its [three focused live cases](evidence/1.1.11/lists/final-focused-results.json) retained all quantities and details: two accepted cleanups and one conservative fallback. These are separate from the B5 full provider studies.

## Research and design

[Typeless’s published Home example](https://www.typeless.com/help/troubleshooting/give-feedback) informed the dashboard metrics. Its public website uses a [45 WPM typing comparison](https://www.typeless.com/). Our estimate additionally subtracts measured recording and result-processing time, includes slow dictations as negative contributions, and makes its assumptions visible. Chinese and mixed-language word boundaries are approximate. Later manual editing and copying are not measured.

The user’s adaptation of [FreeFlow’s public post-processing implementation](https://github.com/zachlatta/freeflow/blob/main/Sources/PostProcessingService.swift) informed the cleanup/command distinction. The built-in prompts are public; they are not proprietary Typeless or Wispr prompts.

## Validation

The usage model passed 34 checks for multilingual text, calendar boundaries, duplicates, invalid timings and signed savings. Concurrency adds 24 checks for ordering, failures, cancellation and preservation of semantic checks. Packaging fixtures passed 90 checks and manual migration passed 13 checks. The final signed universal binary passed **1,015 offline checks**. A final synthetic 6,402-character cleanup completed all four sections in **7.51 seconds**, preserving all 16 records, their ordered content and every protected literal with no fallback. [Exact binary/source hashes and the full synthetic result](evidence/1.1.11/final-build-validation.json) identify what was tested. Native isolated UI checks verified typing into the prompt editor, saving, reopening, draft-only reset, cancellation, date-range filtering and the time-estimate explanation. The app's stable data identity and update feed remain unchanged.

The installer preview passed 25 checks for its real mounted contents, matching app/volume logo, portable native background bookmark, non-overlapping layout and Retina image sizes. Finder visual inspection caught and corrected an initially unresolved background; the working artwork was then checked in Finder. Final packaging separately enforces Developer ID signatures, Apple notarization and Gatekeeper acceptance.

A controlled [six-run scheduling comparison](evidence/1.1.11/latency/provider-comparison/manifest.json) on the same 6,402-character synthetic bilingual input measured median cleanup of 14.86 seconds with sequential processing and 11.42 seconds with two independent sections in parallel (23.2% lower). Every run preserved all 16 records and protected values. This small experiment used a frozen earlier prompt snapshot and measures paragraph scheduling, not short-message latency or microphone capture. Provider timing varies; it is not a promise of a fixed speedup.

This release retains the personal API-key connection. It does not deploy the deferred free hosted service.

These cleanup studies do not exercise microphone recognition or insertion into another app. The concurrency benchmark measures multi-paragraph cleanup, not a continuous microphone recording. Native UI checks used isolated synthetic history and preferences. The executable contains Apple silicon and Intel slices; runtime checks on this Mac were Apple silicon.
