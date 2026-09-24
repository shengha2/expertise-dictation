# Expertise Dictation

Open-source macOS dictation with a default Fn shortcut, multilingual speech, editable public prompts, and restrained rewriting. Requires macOS 14 or later. It does not use Apple's built-in Dictation.

**1.1.9 is in development.** The new onboarding and rewrite changes are being validated. The free service has not been deployed, and native ChatGPT insertion still needs an interactive check. Do not treat a source build as a tested public release. Published DMGs and their actual release notes are in the [release repository](https://github.com/shengha2/expertise-dictation-releases/releases).

## Use it

Click a text field, tap **Fn**, speak, and tap **Fn** again. Hold and release also works. **Esc** cancels. Around twelve seconds without speech ends recording; an empty result disappears quietly. Double-tap Fn from idle to translate into your selected target language.

Setup walks through permissions, a live microphone check, a real shortcut check, a practice dictation and the ready screen. Choose any combination of recognition languages, including Simplified or Traditional Chinese. Your dictionary stays available as its own page.

| Rewrite mode | Behavior |
| --- | --- |
| **Full** — new-install default | Restrained improvements to wording and structure, without summarizing or changing commitments. |
| **Light** | Keeps vocabulary and order while repairing obvious disfluency and punctuation. |
| **No rewrite** | Keeps the text returned by the transcriber; skips rewriting and local replacement/cleanup passes. |

Full and Light protect numbers, addresses, links, code, uncertainty and language switches. A rejected rewrite retains the original. These checks reduce risk; they are not a promise of perfect recognition or meaning preservation. Long recordings are checkpointed locally so interrupted work can be retried. When the destination changes, the complete result is available in a scrollable Copy card.

Read [MINT — the usage guide](MINT.md) for setup, shortcuts, recovery, updates and privacy.

## Public prompts and source

The [prompt files](prompts/README.md), [mode design and research](docs/rewrite-design.md), and [synthetic evaluation cases](evals/rewrite-quality.json) are included. The app's **Edit rewrite prompt…** lets you save a personal Full style; **View all public prompt files** opens the bundled defaults. Meaning checks remain independent of style changes.

The source and project-owned prompts/assets are [MIT licensed](LICENSE). [Third-party notices](THIRD_PARTY_NOTICES.md) preserve the licenses for Sparkle, Inter and the sound cues. Typeless and Wispr Flow informed interaction and rewriting research; their proprietary prompts and assets are not included.

## Free service and personal connections

The intended default is an operator-funded service with no account and no user API key. The [service source](service/README.md) contains a bounded OpenAI relay with anonymous installation tokens, rate limits, daily budget reservations and fixed model choices. It starts disabled until an operator supplies secrets, a deployment and a budget. No OpenAI key is embedded in the app or repository.

Existing personal API-key connections stay selected on upgrade. Advanced users can choose **Use my own API key** in Connection settings. Personal requests are billed to that user's provider account. Fresh source builds without a configured hosted URL show the service as unavailable instead of pretending to offer free inference.

## Build and test

Apple's Command Line Tools are sufficient; Xcode is optional. The supported build downloads a checksum-pinned Sparkle framework and compiles with Swift:

```sh
scripts/build.sh                    # arm64 + x86_64 app bundle
ARCHS=arm64 DEBUG=1 scripts/build.sh  # faster local development
scripts/test.sh                     # offline app checks
```

`BUILD_DIR=/absolute/path` selects an isolated build directory. Source builds are ad-hoc signed unless `SIGN_IDENTITY` names your Developer ID certificate. They can need new Microphone and Accessibility grants. Do not disable Gatekeeper globally.

```sh
"build/Expertise Dictation.app/Contents/MacOS/FnDictate" --selftest
"build/Expertise Dictation.app/Contents/MacOS/FnDictate" --controller-selftest
"build/Expertise Dictation.app/Contents/MacOS/FnDictate" --overlay-selftest
```

Offline controller and overlay checks do not prove live microphone, physical Fn, desktop switching, or paste behavior in a particular app. Real-provider evaluation requires your own configured credentials and may incur a charge; the evaluation script is dry-run by default. See [validation status](docs/release-1.1.9.md) for the measured scope and remaining release gates.

To change defaults, edit `prompts/*.txt`, run `python3 scripts/generate-prompts.py`, and evaluate the fixed cases. Builds reject out-of-sync generated prompts. To connect a deployment, provide `EXPERTISE_SERVICE_URL=https://your-public-service-host` while building. Non-local packaging of 1.1.9 and later requires a valid public HTTPS service origin, including when packaging an already-built app. `HOSTED_SERVICE_REQUIRED=1` also rejects a missing URL during a direct development build. These configuration checks do not replace a live end-to-end deployment test.

## Local data

Preferences use the original `com.hao.fndictate` identity to preserve upgrades. Personal provider keys are stored in a user-permission-restricted JSON file, not encrypted Keychain storage. Optional history, recovery recordings and keys are under `~/Library/Application Support/FnDictate`. Logs are under `~/Library/Logs/FnDictate`. Never publish those directories or private test recordings.

The source distribution excludes local release evidence, credentials, downloaded reference screenshots and installers. The free relay does not persist audio or transcripts; it keeps limited anonymous usage counters. Review its source and your hosting provider's configuration before operating it.
