# 1.1.10: first-recording microphone correction

**Published September 24, 2026.** [Download the Apple-notarized 1.1.10 DMG](https://github.com/shengha2/expertise-dictation-releases/releases/tag/v1.1.10).

## Problem and correction

The first dictation after launch could show “Microphone changed — capture resumed” even when the selected microphone and audio format were unchanged and the engine was running. The old handler treated every audio configuration notification as an interruption, stopped healthy capture and saved a warning for the completed dictation.

The correction checks the actual input device, stream format and running state before rebuilding capture. Redundant notices leave healthy capture alone. Notifications and audio callbacks belong to the recording generation in which they occurred, so a delayed callback cannot restart or feed a later recording. A real stopped engine or changed input still triggers recovery; captured duration is preserved, and restart failures remain visible. Existing recording archives and the five-second audio heartbeat remain in place.

Apple describes this notification as covering input **or output** configuration changes. A notification alone does not establish that the microphone changed or speech was lost. See [Apple’s AVAudioEngine documentation](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange).

## Validation scope

On this Apple-silicon Mac, the old capture implementation produced a first-recording warning on **4 of 4 fresh launches** while the engine was already running with the selected device and 48 kHz mono input. None of their four second recordings warned. The corrected implementation completed **11 recordings across six fresh launches with zero warnings and zero errors**. This covered 16/24 kHz PCM, both microphone preferences, warm reuse, immediate and delayed starts after preparation, and the actual start sound. A 20-second microphone run delivered 19.996 seconds of PCM, with a maximum callback interval of 0.107 seconds. These were capture tests, not speech-recognition accuracy tests. The harness counts PCM and callback timing; it does not store or upload microphone audio or touch settings, dictionary, history or saved keys.

**35 targeted regression checks passed** with real PCM conversion and an injected engine, covering harmless notices, genuine early interruptions, changed devices/formats, repeated notices, stale events/taps, recovery failures and cumulative duration. The final optimized, Developer ID signed universal app passed **821 offline checks**, including these 35 checks; **89 packaging fixtures** also passed. Its executable SHA-256 is `1b58f2dbc60790129285a4b4e2f6dc51e00fd2211a1fde56c40c1f4c13fbf429`. Both Apple-silicon and Intel slices were built and signature-verified; runtime tests used Apple silicon. Hardware changes are simulated through the injected engine. Those simulations do not establish behavior for every physical headset or Bluetooth route. The broader UI, provider and long-transcription evidence remains in the [1.1.9 report](release-1.1.9.md).

A separate four-second microphone check in the final signed app produced 40 level callbacks. Its real startup configuration notice was handled without restarting capture. This checks the release executable, separately from the instrumented harness.

The personal API-key connection, public prompts and existing update channel are unchanged.

## Distribution verification

Apple accepted the app and DMG; both passed stapling and Gatekeeper checks. The downloaded public DMG and signed appcast matched their locally verified hashes. The DMG SHA-256 is `bbf379f7f0438b19ddebd7e484f7b227879d6338456fcf7a87a2075f739e2685`.

Official Sparkle discovery probes representing 1.1.8 and 1.1.9 found 1.1.10; the 1.1.10 probe correctly reported no newer update. These verify discovery, not installation. The live in-app upgrade check is pending because the Mac was locked; no production automatic installation/relaunch is claimed.
