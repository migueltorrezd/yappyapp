#if DEBUG
import Foundation

// NUMBERS: developer harness behind
// --numbers-cleanup-eval <llama-completion> <model.gguf> <cases.json>
// Runs synthetic fixtures (never user data) through the production path for
// each style, with cleanup off (the deterministic pass alone) and on (the
// real cleanup model on the warm llama-server, its prompt line and guard,
// then the pass), and prints each output, whether it is right, and the
// model time. AS SPOKEN with cleanup on is the latency baseline. The
// "model" lane scores the cleanup reply before the pass.
// cases.json: {"cases": [{"language": "en", "text": "...",
//   "digits": {"expect": ["25 people"], "forbid": ["1 of"]},
//   "words": {"expect": [...], "forbid": [...]}}]}
enum NumbersCleanupEval {
    struct Check: Decodable {
        let expect: [String]?
        let forbid: [String]?
    }

    struct Case: Decodable {
        let language: String
        let text: String
        let digits: Check
        let words: Check
    }

    struct Fixtures: Decodable {
        let cases: [Case]
    }

    static func run(completionBinary: String, modelPath: String, casesPath: String) -> Never {
        guard let data = FileManager.default.contents(atPath: casesPath),
              let fixtures = try? JSONDecoder().decode(Fixtures.self, from: data) else {
            print("eval.error=cases unreadable")
            exit(2)
        }
        let server = LlamaServerController.cleanup
        server.synchronize(LlamaServerLaunch(
            binary: CleanupServerPolicy.serverBinaryPath(forRuntimeBinary: completionBinary),
            model: modelPath,
            contextTokens: LLMCleaner.contextTokens
        ))
        guard server.waitUntilReady() else {
            print("eval.error=server not ready")
            exit(2)
        }
        let environment = CleanupEnvironment(
            binaryPath: { _ in completionBinary },
            modelReady: { true },
            modelPath: { modelPath },
            run: { _ in .launchFailed },
            server: { server.complete($0) }
        )

        var score: [String: Int] = [:]
        var total: [String: Int] = [:]
        var modelTimes: [NumberStyle: [Int]] = [:]
        var fellBack: [NumberStyle: Int] = [:]
        for (index, fixture) in fixtures.cases.enumerated() {
            guard let language = NumberLanguage(rawValue: fixture.language) else { continue }
            print("case \(index + 1) [\(language.rawValue)]: \(fixture.text)")
            for style in NumberStyle.allCases {
                let plan = NumberPlan(style: style, language: language)
                let startedAt = Date()
                let cleaned = LLMCleaner.cleanup(text: fixture.text, mode: .clean, numbers: plan, environment: environment)
                modelTimes[style, default: []].append(CleanupLatencyBench.milliseconds(since: startedAt))
                if case .fellBack = cleaned.outcome { fellBack[style, default: 0] += 1 }
                guard style != .asSpoken else {
                    print("  spoken  on  \(note(cleaned.outcome)): \(cleaned.text)")
                    continue
                }
                let check = style == .digits ? fixture.digits : fixture.words
                let off = NumberForms.apply(fixture.text, plan: plan)
                let on = NumberForms.apply(cleaned.text, plan: plan)
                // "model": the cleanup reply alone, before the pass, to show
                // what the prompt line itself does.
                for (lane, output) in [("off", off), ("model", cleaned.text), ("on", on)] {
                    let right = isRight(output, check)
                    for key in ["\(style.rawValue).\(lane)", "\(style.rawValue).\(lane).\(language.rawValue)"] {
                        total[key, default: 0] += 1
                        if right { score[key, default: 0] += 1 }
                    }
                    let detail = lane == "off" ? "" : " \(note(cleaned.outcome))"
                    print("  \(style.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(lane.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(right ? "ok" : "MISS")]\(detail): \(output)")
                }
            }
        }

        // The deterministic pass's own cost over every case, both styles.
        let passStart = Date()
        for fixture in fixtures.cases {
            guard let language = NumberLanguage(rawValue: fixture.language) else { continue }
            _ = NumberForms.apply(fixture.text, plan: NumberPlan(style: .digits, language: language))
            _ = NumberForms.apply(fixture.text, plan: NumberPlan(style: .words, language: language))
        }
        print("eval.passMs.allCasesBothStyles=\(CleanupLatencyBench.milliseconds(since: passStart))")

        for key in total.keys.sorted() {
            print("eval.score.\(key)=\(score[key, default: 0])/\(total[key, default: 0])")
        }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        for style in NumberStyle.allCases {
            let times = modelTimes[style, default: [0]]
            print("eval.modelMs.\(style.rawValue).median=\(median(times)) mean=\(times.reduce(0, +) / max(times.count, 1)) fellBack=\(fellBack[style, default: 0])")
        }
        server.stop()
        exit(0)
    }

    private static func note(_ outcome: CleanupOutcome) -> String {
        switch outcome {
        case .cleaned: "cleaned"
        case .skipped: "skipped"
        case .fellBack(let fallback):
            if case .rejected(let rejection) = fallback { "rejected(\(rejection.rawValue))" } else { "fellBack" }
        }
    }

    static func isRight(_ output: String, _ check: Check) -> Bool {
        let folded = output
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .lowercased()
        let expected = (check.expect ?? []).allSatisfy { folded.contains($0.lowercased()) }
        let forbidden = (check.forbid ?? []).contains { folded.contains($0.lowercased()) }
        return expected && !forbidden
    }
}
#endif
