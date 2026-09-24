# 1.1.9 validation status

Status: **Published on September 24, 2026.** [Download Expertise Dictation 1.1.9](https://github.com/shengha2/expertise-dictation-releases/releases/tag/v1.1.9). The universal app and DMG are Developer ID signed, Apple notarized and stapled. This personal-connection release uses users' own provider API keys; provider charges apply. The free hosted service is deferred and is not included. The test scopes and remaining limitations below are explicit.

## What changed

- Five-step setup with permission guides, a microphone check, an observed shortcut gesture, actual practice insertion and completion. Leaving and returning retains verified work; changed inputs or revoked permissions invalidate the affected checks.
- Home distinguishes incomplete setup, a disconnected shortcut and a service outage. Connection failures offer a direct retry instead of routing users through completed setup.
- Fn remains the default. Existing valid shortcuts, rewrite choices and personal connections survive an upgrade.
- Full rewrite is the fresh-install default, alongside Light and No rewrite. No rewrite bypasses both the rewrite model and local normalization/replacement passes.
- Public editable prompts, restrained Full wording, Chinese punctuation handling, protected literals, independent mixed-language checks and whole-result checks across long-text sections.
- Clipboard ownership tracking for overlapping dictations and clipboard changes immediately before paste.
- An explicit personal release flavor that routes to users' configured providers and omits hosted connection choices. A separate no-account hosted client and open-source Cloudflare service remain in development, with server-side provider credentials, anonymous tokens and bounded usage; they are not enabled in the personal release.
- A downloaded update retains its version and restart action. Automatic restarts wait for safe idle time; pending dictation, results and edits are protected by both queue-time and termination-time checks.

## Why automatic updating appeared broken

The September 24 audit found 1.1.8 installed on this Mac, while the public signed feed still advertised 1.1.7. There was no newer public version to download. A subsequent manual check in that installed app opened Sparkle's up-to-date dialog and reported published version 1.1.7; it did not install an update. A local signed/notarized DMG does not publish an update. The earlier app also lacked the staged-install callback needed for a clear idle/restart handoff and could replace a downloaded state with a generic completed-check message. The candidate addresses those behaviors and adds installed-version/update controls to Home; manual checks bring the updater response forward. The public 1.1.9 DMG and signed feed were downloaded again and matched their locally verified SHA-256 values.

## Measured evidence

The earlier integrated development candidate **a9** builds for both Apple silicon and Intel and is Developer ID signed. It passed **770 offline checks**, **129 controller checks** and **14 native Swift-to-local-Worker checks**. Runtime checks were performed on this Apple-silicon Mac; compiling the Intel slice is not an Intel runtime test. Candidate a9 is a debug validation build with no deployed service origin, not the final personal-connection distribution. The new explicit flavor and Home update controls require validation against the final optimized build; its results will be recorded separately.

The final optimized universal **personal r2** candidate passed **786 offline checks** and **129 controller checks**, with zero failures. It is Developer ID signed, embeds `ExpertiseServiceMode=personal`, and contains no hosted-service URL. Its executable SHA-256 is `2e79cc268a625cc3a027bbf8b0ef1afe312f797e848ad61afbfe20a321f63677`. These counts are separate from the earlier debug candidate. The new menu action preserves the current tab when an inline draft exists and defers a staged restart or open editing sheet with an explanation. An isolated new-build UI attempt was stopped before interactions after its separate test profile was confused with the daily app; it is not counted as a completed native UI test.

The offline total includes 84 updater/draft-state checks and 40 onboarding/Home checks. The controller suite uses injected providers and insertion callbacks; it does not record a microphone or type into an external app.

### Native controls and insertion

Candidate a3 passed 18 native UI observations in an isolated test app: five onboarding screens, help-sheet dismissal, alternate shortcut selection, language selection/search, ordinary keyboard entry, text selection, all three rewrite choices, prompt Save/Cancel and More options. These were real controls, but preview mode deliberately disables microphones, global shortcuts, providers and updater startup. Completion remained disabled without real checks. Candidate a9 passed **13 further native control checks**: Home guidance, leaving setup, retained shortcut-disclosure state, dictionary Add/inline editing, multi-line vocabulary, the three rewrite modes, prompt Save/Cancel and secure synthetic-key draft/Save/Return behavior. Its initial step was selected by a preview flag; that alone is not credited as production resume proof. The retained disclosure state is independent of the flag. Updater startup remained disabled for UI preview; restart behavior has separate fixture evidence.

Candidate a8 also passed four native Copy-card checks: scrolling through 80 sections to a visible end marker, copying all 5,209 characters, clicking Dismiss, and dismissing a separate preview with Escape. These used a unique test-app identity and synthetic text.

Twenty isolated clipboard transaction cases passed. Five reproduced failures before their fixes: overlapping restore ownership, a failed overlapping paste, preserving a newer external copy, capturing the clipboard after focus validation, and aborting if the clipboard changes before paste. This is fixture evidence, not proof of pasting into ChatGPT.

Two safe ChatGPT insertion attempts stopped before typing because the separate browser tab was not visible as the expected native foreground app. Native ChatGPT/Codex inspection was denied by the testing tool. A fresh empty Chrome ChatGPT draft brought forward by the user is still needed for the permitted native insertion check. No existing draft was used.

### Rewrite quality

The fixed short-text suite ran 46 real-provider cleanup cases on candidate a4. Agent review against declared criteria found **44 quality passes, one partial Light rewrite and one safe original-text fallback**, with no provider errors or accepted meaning/language failures observed. A case can make more than one provider request because Full may include independent verification. These are not 46 HTTP requests or a human usability study. The former holdout was kept separate initially; subsequent runs are known regression cases.

The remaining partial retained an abandoned English request; the fallback rejected a punctuation change inside quoted text. A fallback protects content but is not counted as a successful rewrite.

The long fixture contains **28,776 characters and 72 distinct records**, including owners, reviewers, deadlines, numbers, emails, URLs, file paths, uncertainty and explicit prohibitions. Automatic review checks record order/multiplicity, per-record words and numbers, literals and reconstruction, with agent inspection of rejected sections. It is synthetic text cleanup, not a microphone-duration trial.

The first long runs preserved all records but exposed poor section boundaries. Candidate a6 kept paragraphs and bounded literals intact, yet repeated preceding-paragraph context triggered nine Full and four Light fallbacks. Candidate a8 removes that context only at real source newline boundaries, retaining initial insertion context and genuine same-paragraph continuation. In the final rerun, **Full and Light each accepted all 18 sections with zero guard or provider fallbacks**. All 72 records and their per-record words, numbers and literals were preserved in order. Agent review found readable Chinese punctuation, sensible Full paragraph breaks and no duplicated prior context. Full took **132.5 seconds** and Light **117.6 seconds**. This is one synthetic long case per mode, not a broad semantic benchmark or an audio recording test. Earlier unsuccessful and timeout-limited runs remain recorded rather than being overwritten.

### Service and packaging

The local service suite passed **41 tests** covering authentication, HTTP/WebSocket contracts, budget races, rate limits and failure handling. Candidates a5 and a9 each passed **14 native Swift-to-Worker checks**, including queued audio, transcription/cleanup parsing, a rejected WebSocket handshake and successful explicit retry with refreshed access. OpenAI upstreams were simulated in these tests; they did not use the microphone or prove a public service deployment.

The earlier **64 mocked packaging cases** passed, including public-source export and rejection of hosted 1.1.9+ releases when the embedded service origin is missing or unsafe. The explicit personal-release change adds **25 separate flavor cases**; the combined **89-case suite passed**. New cases cover personal build stamping, removing a stale hosted URL before signing, mixed/unknown flavor rejection, personal source-export packaging, preserved signing/notary failures, and environment variables being unable to override a signed bundle's mode. Direct and SKIP_BUILD packaging inspect the signed app's actual plist and do not mutate it. A valid-looking hosted origin alone is not a live health check. No Apple submission or installation occurred in these fixtures. These packaging results do not relabel the earlier a9 binary as a personal build; the final personal artifact needs its own validation.

### Real updater handoff

A disposable native app exercised the actual updater adapter and pinned Sparkle framework. **All 12 checks passed**: signed loopback feed/archive download, extraction, staging through recording/Copy/editing holds, a 15-second safe-idle interval, one deliberately canceled termination, a fresh idle interval, actual replacement from fixture version 1 to 2, and relaunch under a new process. The run took **47.99 seconds** and used a temporary bundle identity and disposable signing key; production keys, feed and installed app were untouched.

The fixture changed only configuration validation to accept its restricted loopback origin/temporary identity and added an immediate background-check trigger. Production staged, idle and relaunch code remained unchanged. Its ad-hoc-signed ZIP does not prove Developer ID/notarization, production DMG layout, GitHub delivery, or an existing user's upgrade. An earlier direct-executable fixture did not complete installation within its deadline; both launch method and location changed before the successful run, so that earlier cause remains unisolated and the failed evidence is retained.

A separate rerun against the updated updater source also passed **12 of 12 checks** in **47.95 seconds**, including actual disposable version-1-to-2 replacement and relaunch. This has the same fixture-only scope and does not establish a production DMG upgrade.

### Overlay limitations

Candidate a4 failed a native panel-focus check and nine visibility checks. Candidates a5 and a6 each passed all 48 isolated sizing, focus, layout and simulated workspace checks without a production overlay change between the failure and reruns. Candidate a9 reproduced the focus and nine visibility failures, both by direct execution and with a unique test bundle launched normally through LaunchServices. Duplicate identity or direct launch alone does not explain the failure. Two isolated lifecycle experiments also did not produce a full pass. Running the synchronous assertions on the main dispatch queue interfered with scheduled recovery; a run-loop timer restored those checks but still failed focus/visibility. No production overlay code or assertions were changed. A subsequent read-only session probe reported **the Mac was locked**. That observation does not establish every earlier run’s exact lock state or the cause of all earlier failures. Those failed results remain preserved for comparison; no production overlay fix is claimed from the diagnostic changes. These tests do not exercise a real trackpad swipe, full-screen transition or every macOS window arrangement.

A later active-console run of the **same frozen Timer diagnostic** passed all **48 checks** (15 workspace, 21 Copy layout and 12 visibility), plus the preview/recording focus predicates. Its overlay source matches the production source at that check. Panels were reported unoccluded and at their tested midpoint. The probe's lock field was absent, so the run is not labeled an affirmative unlocked-Boolean measurement. This single successful rerun is consistent with an environment confound; it does not identify the exact cause of every earlier failure. It uses the a9-source diagnostic, not the final release binary, and still does not test actual desktop/full-screen gestures.

## Personal release status and known limitations

- Apple accepted both app and DMG; stapling, Gatekeeper and public-download checks passed. The DMG SHA-256 is `063afbd8833e42cf9f8e29f18305a4009295f45829c2ee631d6c9928f50423c8`. The existing signed update feed now offers 1.1.9. Official Sparkle information probes using isolated 1.1.7 and 1.1.8 host versions both discovered 1.1.9, and a 1.1.9 host correctly reported no newer update. These are discovery checks, not installed upgrade cycles. The downloaded notarized DMG was also installed manually over this Mac's 1.1.8 app, with the prior app backed up; native post-install checks are recorded separately.
- Actual desktop swipes, full-screen transitions and native ChatGPT insertion remain unverified; the synthetic/native fixture results above do not imply those paths passed.
- Hosted-service deployment and real speech through that gateway are deferred work for a later hosted release. They are not dependencies of the explicitly personal bundle.
- A complete production DMG update/relaunch remains unverified. Both disposable updater runs are separate evidence; final public discovery and download verification do not by themselves establish an existing user's installed upgrade.

No result establishes perfect behavior in every app, Space, microphone or network condition. Historical long-recording reports describe their own versions and cannot establish the new hosted path's reliability.
