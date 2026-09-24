import Foundation

/// Generated PCM and injected uptime exercise inactivity behavior without microphone/network
/// access or real-time waits. These are heuristic bounds, not claims of universal speech VAD.
enum AudioSilenceMonitorTests {
    static func run(check: (String, Bool, String) -> Void) {
        let monitor = AudioSilenceMonitor()
        var session = UUID()
        func expect(_ name: String, _ passed: Bool) { check("silence: \(name)", passed, "") }
        func restart(at now: Double = 0) {
            session = UUID()
            monitor.reset(sessionID: session, now: now)
        }
        func feed(_ data: Data, rate: Double = 24_000, ending now: Double) {
            monitor.observe(pcm16: data, sampleRate: rate, sessionID: session, now: now)
        }
        let silence = pcm(seconds: 1) { _ in 0 }

        restart()
        for second in 1...11 { feed(silence, ending: Double(second)) }
        expect("initial silence does not finish before twelve seconds", !monitor.shouldFinish(sessionID: session, now: 11.999))
        feed(silence, ending: 12)
        expect("initial silence finishes at twelve seconds", monitor.shouldFinish(sessionID: session, now: 12))

        for rate in [16_000.0, 24_000.0] {
            restart()
            let speech = pcm(seconds: 1, rate: rate, signal: syllables)
            feed(speech, rate: rate, ending: 3)
            expect("speech resets the inactivity deadline at \(Int(rate))Hz", !monitor.shouldFinish(sessionID: session, now: 13))
            expect("a pause shorter than twelve seconds is preserved at \(Int(rate))Hz", !monitor.shouldFinish(sessionID: session, now: 14.5))
            expect("silence after speech eventually finishes at \(Int(rate))Hz", monitor.shouldFinish(sessionID: session, now: 15))
        }

        restart()
        feed(pcm(seconds: 1, signal: syllables), ending: 1)
        feed(pcm(seconds: 1, signal: syllables), ending: 10)
        expect("speech after a short pause starts another full interval", !monitor.shouldFinish(sessionID: session, now: 20))
        expect("a later twelve-second pause still finishes", monitor.shouldFinish(sessionID: session, now: 22))

        restart()
        monitor.noteTranscriptActivity(" quiet speech ", sessionID: session, now: 10)
        monitor.noteTranscriptActivity("quiet  speech\n", sessionID: session, now: 20)
        monitor.noteTranscriptActivity(" \n", sessionID: session, now: 21)
        expect("changed transcript evidence protects very quiet speech", !monitor.shouldFinish(sessionID: session, now: 21))
        expect("identical or whitespace-only partials cannot extend silence forever", monitor.shouldFinish(sessionID: session, now: 22))
        monitor.noteTranscriptActivity("quiet speech continues", sessionID: session, now: 22)
        expect("new transcript words refresh the deadline", !monitor.shouldFinish(sessionID: session, now: 33))

        restart()
        let oldSession = session
        restart(at: 100)
        monitor.observe(pcm16: pcm(seconds: 1, signal: syllables), sampleRate: 24_000, sessionID: oldSession, now: 110)
        monitor.noteTranscriptActivity("stale speech", sessionID: oldSession, now: 111)
        expect("late audio and transcript callbacks cannot affect a new session", monitor.shouldFinish(sessionID: session, now: 112))
        expect("polling an old session cannot finish the current recording", !monitor.shouldFinish(sessionID: oldSession, now: 200))

        restart()
        for second in 1...13 {
            let background = pcm(seconds: 1) { t in 0.0008 * sin(2 * .pi * 120 * t) }
            feed(background, ending: Double(second))
        }
        expect("continuous quiet background does not keep capture alive", monitor.shouldFinish(sessionID: session, now: 13))

        restart()
        let hum = pcm(seconds: 1) { t in 0.03 * sin(2 * .pi * 100 * t) }
        for second in 1...14 { feed(hum, ending: Double(second)) }
        expect("steady audible hum does not extend the timer indefinitely", monitor.shouldFinish(sessionID: session, now: 14))

        restart()
        var seed: UInt64 = 7
        let fan = pcm(seconds: 1) { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return (Double((seed >> 32) & 0xffff) / 32_767.5 - 1) * 0.015
        }
        for second in 1...14 { feed(fan, ending: Double(second)) }
        expect("stationary noise does not extend the timer indefinitely", monitor.shouldFinish(sessionID: session, now: 14))

        restart()
        let clicks = pcm(seconds: 1) { t in t < 0.002 ? 0.5 * sin(2 * .pi * 1_000 * t) : 0 }
        for second in 1...12 { feed(clicks, ending: Double(second)) }
        expect("isolated repeated clicks do not count as ongoing speech", monitor.shouldFinish(sessionID: session, now: 12))

        restart()
        let dc = pcm(seconds: 1) { _ in 0.2 }
        for second in 1...12 { feed(dc, ending: Double(second)) }
        expect("a constant DC offset is not acoustic activity", monitor.shouldFinish(sessionID: session, now: 12))

        restart()
        feed(silence, ending: 10)
        feed(pcm(seconds: 1, signal: syllables), ending: 9)
        expect("out-of-order audio timestamps do not refresh activity", monitor.shouldFinish(sessionID: session, now: 12))
        monitor.observe(pcm16: Data([1]), sampleRate: 24_000, sessionID: session, now: 13)
        monitor.observe(pcm16: silence, sampleRate: .nan, sessionID: session, now: 13)
        expect("invalid PCM or sample rates cannot refresh activity", monitor.shouldFinish(sessionID: session, now: 13))
        expect("nonfinite or backward poll times never finish", !monitor.shouldFinish(sessionID: session, now: .nan) && !monitor.shouldFinish(sessionID: session, now: -1))
    }

    private static func syllables(_ time: Double) -> Double {
        let envelope = 0.2 + 0.8 * pow(sin(.pi * 4 * time), 2)
        return envelope * (0.04 * sin(2 * .pi * 180 * time) + 0.015 * sin(2 * .pi * 360 * time))
    }

    private static func pcm(seconds: Double, rate: Double = 24_000, signal: (Double) -> Double) -> Data {
        var data = Data(capacity: Int(seconds * rate) * 2)
        for index in 0..<Int(seconds * rate) {
            let value = Int16((max(-1, min(0.999, signal(Double(index) / rate))) * 32_768).rounded())
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
}
