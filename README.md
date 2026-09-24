# Expertise Typer

Open-source macOS dictation with a default Fn shortcut, multilingual speech, editable public prompts, and restrained rewriting. Requires macOS 14 or later. It does not use Apple's built-in Dictation.

Previously **Expertise Dictation**. Version 1.1.11 introduces the Expertise Typer name while keeping the same app identity, dictionary, saved connection and update channel. Existing release URLs retain their original names.

**The Mac release uses your own provider API key.** Existing personal connections carry over; new users add their key during setup. Provider charges apply. The free hosted service is deferred and is not included in this release. Published DMGs and their actual release status are in the [release repository](https://github.com/shengha2/expertise-dictation-releases/releases); the [1.1.11 report](docs/release-1.1.11.md) covers the new name, dashboard, prompts and list formatting; the [1.1.10 validation report](docs/release-1.1.10.md) covers the first-recording microphone fix, and the [1.1.9 report](docs/release-1.1.9.md) records broader validation and remaining limitations. A source build is not proof of a tested public release.

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

The [prompt files](prompts/README.md), [mode design and research](docs/rewrite-design.md), and [synthetic evaluation cases](evals/rewrite-quality.json) are included. The app's **Home → View and edit prompt…** lets you save personal Full instructions; **Reset to default**, then Save, restores the current built-in prompt; **View all public prompt files** opens the bundled defaults. Meaning checks remain independent of style changes.

Home also shows words, dictation time, speaking speed and estimated time saved, with daily activity. The estimate assumes 45 typing words per minute and subtracts recording and processing time; it uses the history still saved on this Mac.

The source and project-owned prompts/assets are [MIT licensed](LICENSE). [Third-party notices](THIRD_PARTY_NOTICES.md) preserve the licenses for Sparkle, Inter and the sound cues. Typeless and Wispr Flow informed interaction and rewriting research; their proprietary prompts and assets are not included.

## Personal connection release and future hosted service

The personal release asks for your provider API key under **Preferences → More options → Connection**. Existing keys and personal provider choices stay selected on upgrade. Requests go to your selected provider and are billed to that account. No provider key is embedded in the app or repository.

The future operator-funded mode is separate. Its [service source](service/README.md) contains a bounded OpenAI relay with anonymous installation tokens, rate limits, daily budget reservations and fixed model choices. It remains disabled and undeployed. A personal bundle does not offer or route requests through that service. Ordinary source builds still default to hosted mode and show it unavailable without a deployment; choose the personal flavor explicitly to use the app with your own key.

## Build and test

Apple's Command Line Tools are sufficient; Xcode is optional. The supported build downloads a checksum-pinned Sparkle framework and compiles with Swift:

```sh
scripts/build.sh                    # arm64 + x86_64 app bundle
ARCHS=arm64 DEBUG=1 scripts/build.sh  # faster local development
EXPERTISE_SERVICE_MODE=personal scripts/build.sh  # explicit own-key app bundle
scripts/test.sh                     # offline app checks
```

`BUILD_DIR=/absolute/path` selects an isolated build directory. Source builds are ad-hoc signed unless `SIGN_IDENTITY` names your Developer ID certificate. They can need new Microphone and Accessibility grants. Do not disable Gatekeeper globally.

```sh
"build/Expertise Typer.app/Contents/MacOS/FnDictate" --selftest
"build/Expertise Typer.app/Contents/MacOS/FnDictate" --controller-selftest
"build/Expertise Typer.app/Contents/MacOS/FnDictate" --overlay-selftest
```

Offline controller and overlay checks do not prove live microphone, physical Fn, desktop switching, or paste behavior in a particular app. Real-provider evaluation requires your own configured credentials and may incur a charge; the evaluation script is dry-run by default. See [validation status](docs/release-1.1.9.md) for the measured scope and remaining release gates.

To change defaults, edit `prompts/*.txt`, run `python3 scripts/generate-prompts.py`, and evaluate the fixed cases. Builds reject out-of-sync generated prompts. For a personal release, set `EXPERTISE_SERVICE_MODE=personal` and leave `EXPERTISE_SERVICE_URL` unset. For hosted mode, set `EXPERTISE_SERVICE_MODE=hosted` and `EXPERTISE_SERVICE_URL=https://your-public-service-host` before building. Non-local packaging of 1.1.9 and later inspects the signed app's embedded flavor: personal must omit the hosted URL; hosted must contain a valid public HTTPS origin. Missing configuration never silently selects personal mode. `HOSTED_SERVICE_REQUIRED=1` explicitly requires hosted configuration, including during development, and conflicts with personal mode. These configuration checks do not replace a live end-to-end service test.

## Local data

Preferences use the original `com.hao.fndictate` identity to preserve upgrades. Personal provider keys are stored in a user-permission-restricted JSON file, not encrypted Keychain storage. Optional history, recovery recordings and keys are under `~/Library/Application Support/FnDictate`. Logs are under `~/Library/Logs/FnDictate`. Never publish those directories or private test recordings.

The source distribution excludes local release evidence, credentials, downloaded reference screenshots and installers. The free relay does not persist audio or transcripts; it keeps limited anonymous usage counters. Review its source and your hosting provider's configuration before operating it.
