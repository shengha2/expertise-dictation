# Public dictation prompts

These UTF-8 files are the app's public default instructions. They describe our implementation, not Typeless or Wispr Flow's proprietary prompts.

The current defaults use the user's requested cleanup contract: edit spoken text into natural writing while preserving its content, and use vocabulary or context only to resolve spelling. The supplied [FreeFlow post-processing reference](https://raw.githubusercontent.com/zachlatta/freeflow/main/Sources/PostProcessingService.swift), reviewed on September 24, 2026, also distinguishes transcript cleanup from a separate selected-text editing mode. Dictation here continues to treat spoken requests as text; the reference's command mode is not enabled. Our defaults retain the requested English/Chinese list formatting, independent fidelity checks and exact-literal protections.

| File | Used for |
| --- | --- |
| [full-rewrite.txt](full-rewrite.txt) | Full mode's editable style instructions: restrained rewriting and readable structure. |
| [light-cleanup.txt](light-cleanup.txt) | The shared Light-mode contract, used by both detailed and compact prompt compositions. |
| [punctuation.txt](punctuation.txt) | Chinese, English and mixed-language punctuation guidance in both modes. |
| [rewrite-verifier.txt](rewrite-verifier.txt) | The independent Full-mode semantic check. |

Edit a text file, then run:

```sh
python3 scripts/generate-prompts.py
python3 scripts/generate-prompts.py --check
```

The generator produces `Sources/FnDictate/PublicPromptDefaults.swift`. These exact strings are compiled into the signed app. There is no network download of a prompt, and editing a repository file does not modify an already installed app.

The complete request is composed in `CleanupPrompt.swift`: language/script choice, spacing, spoken-command preference, dictionary, replacements, insertion context, and fixed fidelity constraints are added for each dictation. The detailed Light prompt also supplies explicit correction examples. Numeric/address/literal checks and the raw-text fallback are implemented independently of these files.

In the app, **Preferences → Edit rewrite prompt…** edits Full's style text. Save affects subsequent dictations; Cancel discards the draft; Restore default followed by Save resumes the built-in default, including future app updates. A saved custom style stays saved across updates. The in-app editor does not disable the independent fidelity checks. Light currently uses the public built-in defaults; None has no rewrite prompt or rewrite-model request.

Before proposing a default change, evaluate both modes against [the fixed quality cases](../evals/rewrite-quality.json). Report the proposed and final outputs, not only accepted examples. A semantic rejection that returns the original is a safe fallback, not a successful rewrite. See [the mode contract and research](../docs/rewrite-design.md).
