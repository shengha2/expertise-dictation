# Readable dictation without changing the message

Design research reviewed September 23, 2026. This document describes our intended behavior and evaluation criteria, not a claim that a candidate build has passed them.

## What the official product guidance establishes

[Wispr Flow Auto Cleanup](https://docs.wisprflow.ai/articles/4283510616-auto-cleanup-control-how-much-flow-edits-your-dictation-beta) distinguishes raw output, light edits, and a more substantial clarity pass. Its current documentation calls those choices None, Light, and Medium, with Light as its default. It says a choice takes effect on the next dictation and describes examples in the picker. Those are useful interaction patterns; our user's requested default is Full.

[Wispr Flow Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-How-do-I-use-Smart-Formatting-%26-Backtrack) documents multilingual punctuation, continuation of existing sentences, lists signaled by sequence words, and removal of clear self-corrections. Its examples distinguish an actual correction from meaningful uses of words such as “actually.” This supports conservative correction and respecting the insertion context rather than treating every conversational connector as disposable.

[Typeless's official product page](https://www.typeless.com/) advertises filler/repetition removal, final-intent correction, automatic list structure, personal vocabulary, and mixed-language dictation. Its style adaptation is a product claim, not evidence that any particular undocumented prompt produces equivalent behavior. We have no access to either company's proprietary prompts, training data, or evaluation results.

[OpenAI's model optimization guidance](https://developers.openai.com/api/docs/guides/model-optimization) recommends testing against representative data and iterating on prompts using measured results. [GPT-6 Luna's model page](https://developers.openai.com/api/docs/models/gpt-6-luna) documents Chat Completions and the supported reasoning settings. We retain the selected model and evaluate the actual application path; changing a prompt is not proof of better output.

## Mode contract

| Mode | Intended output | Never allowed |
| --- | --- | --- |
| Full — default for a new installation | Natural wording, punctuation and readable sentence/paragraph structure. A small list when genuinely helpful. Keep a short message short. | Summarizing, inventing commitments or details, needless formality, translation, turning a dictated request into an answer. |
| Light | Preserve the speaker's vocabulary and order. Remove obvious disfluency and repair punctuation; retain meaningful repetition, hedges and alternatives. | General paraphrasing, rearranging the argument, manufacturing a list, interpreting uncertainty as a decision. |
| None | Keep the transcription engine's returned text; it may already contain the engine's punctuation. No rewrite-model request. | Advertising raw audio word-for-word accuracy, or silently applying a rewriting prompt. |

Keep existing users' explicit mode and saved prompt choices. Edits saved while recording should affect the next dictation. Present the three modes together with a short example; place the prompt editor beside them rather than adding another group of daily settings.

## Chinese and multilingual punctuation

Punctuation follows the sentence's language, not the last word's alphabet. For example, a Chinese sentence ending in an English technical term still normally ends with `。`. Keep an English clause in English; do not translate it to make the punctuation easier. Simplified and Traditional Chinese share these sentence-boundary requirements.

For mixed Chinese/English dictation, preserve the complete sequence of English words even in Full mode, apart from obvious hesitation sounds and casing/punctuation. A deterministic guard enforces this because the semantic verifier has incorrectly accepted a translated English deadline phrase in testing. This deliberately favors keeping code-switches over rephrasing the English portions; an entirely English transcript can still be reworded in Full mode.

Use `，` for related clauses and `。` for completed thoughts. Questions retain question marks and uncertainty. Avoid replacing every pause with a comma, adding a full stop after every conjunction, or forcing each sentence into its own paragraph.

The model can infer missing sentence boundaries from context. A deterministic pass can safely standardize an existing punctuation glyph only with clear Chinese context; it must not guess where words become a new sentence. URLs, email addresses, decimal/version numbers, paths and code are literal values, not punctuation opportunities. Light-mode skipping must not count a dot inside such a value as proof that the prose is punctuated.

Preserve existing whitespace around unquoted filenames and paths. For example, removing the gap in `打开 中文.swift` makes it ambiguous whether `打开` is prose or part of the filename. The prompt preserves that boundary; the guard retains the original if a proposed change still makes the literal ambiguous. It does not guess a Chinese verb prefix or accept any filename suffix.

An empty cleanup result is accepted only for an empty source or a narrowly recognized sequence of hesitation sounds. Standalone meaningful words, questions, numbers, addresses, quoted sounds and code are not empty speech. A clear correction can remove its abandoned wording, but must keep the replacement and independent mentions elsewhere. Ambiguous and broader correction rewrites may still safely retain the original, especially in Light mode.

## Validation before release

[The evaluation dataset](../evals/rewrite-quality.json) contains synthetic English, Simplified Chinese, Traditional Chinese, and mixed-language inputs. Its reference outputs are illustrations, not exact-string gold answers. Each case lists invariants and mode-specific criteria. None has an exact input-equals-output contract; Light and Full need semantic and readability review.

Evaluate a fixed baseline and candidate with the same recorded inputs and settings. Record model, prompt/source hashes, mode, input, proposed output, final output, semantic verdict, fallbacks, elapsed time, and any error. Never count a preserved-raw fallback as a successful rewrite. Do not retry only bad examples or silently omit them. Holdout cases must not be incorporated as prompt examples while tuning the candidate.

Candidate A2 was the first run of the untouched holdout. Fixes informed by those findings make its later reruns known regression checks, not a fresh holdout. The separate [long synthetic fixture](../evals/rewrite-long-quality.json) exercises at least ten cleanup sections with numbered records, owners, deadlines and exact literals. Its checker records every section boundary and verifies completeness per record. Semantic and readability review remains separate; this is text-processing evidence, not proof of microphone recording duration or a live hosted relay.

Long cleanup preserves existing paragraph/line boundaries first, then complete sentence endings, then whitespace within the bounded tail of a request. A bounded URL, path, quote or code span remains in one section. A later section starting a new source paragraph receives no preceding-paragraph fragment to continue; the first section retains external insertion context, and a genuine same-paragraph continuation keeps its preceding output. An oversized literal still splits within the request budget; the final integrity guard may keep the original when that unavoidable split produces an unsafe rewrite. This is a completeness fallback, not a successful polish result. Source sections must always reassemble exactly before any model work.

Release acceptance requires no lost or invented facts, altered numbers/addresses/code, removed negation/uncertainty, or performed dictated instructions. Review punctuation and mode distinction separately from fidelity. Report individual failures and fallback counts; a small synthetic evaluation is not a population accuracy estimate or a long-recording reliability test.
