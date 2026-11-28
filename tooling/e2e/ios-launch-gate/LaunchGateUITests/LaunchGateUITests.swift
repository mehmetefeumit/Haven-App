// The iOS launch gate's journeys (docs/LAUNCH_GATE.md), run by
// tooling/e2e/ci/run-launch-gate-ios.sh against the app it installed on the
// simulator. This bundle has no host app: it drives the installed
// com.oblivioustech.haven by bundle id, so what runs is the build under test,
// started from the OS through its production main().
//
// Every label comes from the ARB of the build being driven, through the
// runner's TEST_RUNNER_GATE_* environment, so a previous release is driven in
// its own words. The display name is held in memory and compared, never
// printed: a failure message names ARB keys, a step, the app's state and
// whether it exposes any element or text, nothing the app shows.
// Across the upgrade's two runs the name crosses only as a digest salted with a
// value the runner never prints.

import CryptoKit
import XCTest

// The longest test, the fresh one, can wait launch + journey + launch (the stop)
// + launch + relaunch + restore = 540 s, inside the 600 s XCTest allowance the
// runner passes.
private enum Bound {
    static let launch: TimeInterval = 60
    // Covers the app's own 60 s finishing-setup wait and three screens.
    static let journey: TimeInterval = 240
    static let progress: TimeInterval = 30
    static let hittable: TimeInterval = 10
    static let errorSettle: TimeInterval = 5
    static let relaunch: TimeInterval = 90
    static let restore: TimeInterval = 30
}

private enum Key: String, CaseIterable {
    case welcome = "onboardingWelcomeCta"
    case create = "onboardingCreateIdentityCta"
    case notNow = "locationDisclosureNotNow"
    case setupHeld = "onboardingFinishSetupError"
    case map = "commonSettings"
    case createError = "onboardingCreateIdentityError"
    case nameError = "onboardingDisplayNameError"

    var environmentName: String {
        switch self {
        case .welcome: return "GATE_WELCOME_CTA"
        case .create: return "GATE_CREATE_CTA"
        case .notNow: return "GATE_DISCLOSURE_NOT_NOW"
        case .setupHeld: return "GATE_SETUP_HELD"
        case .map: return "GATE_MAP"
        case .createError: return "GATE_CREATE_ERROR"
        case .nameError: return "GATE_NAME_ERROR"
        }
    }

    static let failures: [Key] = [.createError, .nameError]
}

private enum Terminal: String {
    case setupHeld = "SETUP_HELD"
    case map = "MAP"
}

private struct GateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func environment(_ name: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
    return value
}

private func saltedDigest(_ name: String, salt: String) -> String {
    SHA256.hash(data: Data((salt + "\u{0}" + name).utf8)).map { String(format: "%02x", $0) }.joined()
}

@MainActor
private final class Journey {
    let app: XCUIApplication
    private let labels: [Key: String]

    init() throws {
        var labels: [Key: String] = [:]
        for key in Key.allCases {
            labels[key] = environment(key.environmentName)
        }
        // A build whose ARB lacks an optional key simply has no such state.
        for key in [Key.welcome, .create, .map] where labels[key] == nil {
            throw GateFailure("no label for \(key.rawValue) was passed in \(key.environmentName)")
        }
        self.labels = labels
        app = XCUIApplication(bundleIdentifier: "com.oblivioustech.haven")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    // A Flutter node can carry several semantics strings joined by newlines
    // (label and tooltip), so a label matches a whole line of it.
    private func linePredicate(_ text: String) -> NSPredicate {
        NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@ OR label ENDSWITH %@ OR label CONTAINS %@",
            text, text + "\n", "\n" + text, "\n" + text + "\n")
    }

    private func element(_ key: Key) -> XCUIElement {
        app.descendants(matching: .any).matching(linePredicate(labels[key]!)).firstMatch
    }

    func launch(_ step: String) throws {
        app.launch()
        guard app.wait(for: .runningForeground, timeout: Bound.launch) else {
            throw GateFailure("the app did not reach the foreground within \(Int(Bound.launch)) s at \(step); \(seen())")
        }
    }

    func relaunchCold() throws {
        app.terminate()
        guard app.wait(for: .notRunning, timeout: Bound.launch) else {
            throw GateFailure("the app did not stop within \(Int(Bound.launch)) s of terminate(); \(seen())")
        }
        try launch("the cold relaunch")
    }

    func requireForeground(_ step: String) throws {
        let state = app.state
        guard state == .runningForeground else {
            throw GateFailure("the app is not running in the foreground (state \(stateName(state))) at \(step)")
        }
    }

    private func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .runningBackground: return "runningBackground"
        case .runningForeground: return "runningForeground"
        default: return "unknown(\(state.rawValue))"
        }
    }

    // Every line of the labels below the app element (whose own label is the
    // app's name), and how many elements there are.
    private func scan(_ root: XCUIElementSnapshot) -> (lines: Set<String>, elements: Int) {
        var lines = Set<String>()
        var elements = 0
        var stack = root.children
        while let node = stack.popLast() {
            elements += 1
            for line in node.label.split(separator: "\n") {
                lines.insert(String(line))
            }
            stack.append(contentsOf: node.children)
        }
        return (lines, elements)
    }

    private func keys(in lines: Set<String>) -> Set<Key> {
        Set(labels.compactMap { lines.contains($0.value) ? $0.key : nil })
    }

    // One snapshot per observation: the keys whose label is a whole line of
    // any element's label.
    func visibleKeys() throws -> Set<Key> {
        try keys(in: scan(app.snapshot()).lines)
    }

    // What a failure says about the screen: the ARB key names shown, whether
    // the app exposes any element and any text (the launch screen, shown up
    // to Flutter's first frame, has no text), and its state. Never a label:
    // the screen holds the display name.
    func seen() -> String {
        let state = app.state
        // An app that is not running has no screen to query.
        guard state != .notRunning, state != .unknown, let root = try? app.snapshot() else {
            return "on screen: no snapshot; app \(stateName(state))"
        }
        let (lines, elements) = scan(root)
        let shown = keys(in: lines).map(\.rawValue).sorted().joined(separator: ", ")
        let text = elements == 0 ? "no element" : lines.isEmpty ? "no labelled element" : "labelled elements"
        return "on screen: keys [\(shown)], \(text); app \(stateName(state))"
    }

    // Returns as soon as any known label is on screen, or when `timeout` ends.
    func awaitAnyKnown(_ timeout: TimeInterval) {
        guard timeout > 0 else { return }
        let any = NSCompoundPredicate(orPredicateWithSubpredicates: labels.values.map(linePredicate))
        let first = app.descendants(matching: .any).matching(any).firstMatch
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: first)
        _ = XCTWaiter.wait(for: [shown], timeout: timeout)
    }

    func failIfError(_ visible: Set<Key>, at step: String) throws {
        if let error = Key.failures.first(where: visible.contains) {
            throw GateFailure("the app showed \(error.rawValue) at \(step)")
        }
    }

    // A CTA the journey already tapped is back: name the error that brought it
    // back if one shows up, else say the journey did not move.
    func failRepeated(_ key: Key) throws -> Never {
        let error = NSCompoundPredicate(
            orPredicateWithSubpredicates: Key.failures.compactMap { labels[$0] }.map(linePredicate))
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.descendants(matching: .any).matching(error).firstMatch)
        _ = XCTWaiter.wait(for: [shown], timeout: Bound.errorSettle)
        try failIfError(try visibleKeys(), at: "\(key.rawValue) shown again")
        throw GateFailure("\(key.rawValue) was shown again after it was tapped: the journey did not progress; \(seen())")
    }

    func tap(_ key: Key, remaining: TimeInterval) throws {
        let target = element(key)
        if !target.isHittable {
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: target)
            guard XCTWaiter.wait(for: [hittable], timeout: Bound.hittable) == .completed else {
                throw GateFailure("\(key.rawValue) is shown but not hittable within \(Int(Bound.hittable)) s; \(seen())")
            }
        }
        target.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        guard XCTWaiter.wait(for: [gone], timeout: min(Bound.progress, max(remaining, 1))) == .completed else {
            try failIfError(try visibleKeys(), at: "after tapping \(key.rawValue)")
            throw GateFailure("the journey did not progress past \(key.rawValue) within \(Int(Bound.progress)) s; \(seen())")
        }
    }

    // The one display-name field's text.
    func displayName() throws -> String {
        let fields = app.textFields
        guard fields.count == 1 else {
            throw GateFailure("the create-identity screen shows \(fields.count) text fields, not one")
        }
        guard let name = fields.element(boundBy: 0).value as? String, !name.isEmpty else {
            throw GateFailure("the display-name field holds no name")
        }
        return name
    }

    // Onboarding from wherever the app opens to a terminal screen, tapping
    // each CTA at most once. Returns the terminal and the name the create
    // screen offered.
    func onboard() throws -> (Terminal, String) {
        let deadline = Date().addingTimeInterval(Bound.journey)
        var tapped = Set<Key>()
        var name: String?
        while true {
            try requireForeground("the onboarding journey")
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw GateFailure("no terminal screen within \(Int(Bound.journey)) s; tapped \(tapped.map(\.rawValue).sorted()); \(seen())")
            }
            awaitAnyKnown(remaining)
            try requireForeground("the onboarding journey")
            let visible = try visibleKeys()
            try failIfError(visible, at: "the onboarding journey")
            if visible.contains(.setupHeld) || visible.contains(.map) {
                guard let held = name else {
                    throw GateFailure("a terminal screen appeared before the create-identity screen was seen; \(seen())")
                }
                return (visible.contains(.setupHeld) ? .setupHeld : .map, held)
            }
            guard let cta = [Key.notNow, .create, .welcome].first(where: visible.contains) else { continue }
            if tapped.contains(cta) { try failRepeated(cta) }
            if cta == .create { name = try displayName() }
            try tap(cta, remaining: deadline.timeIntervalSinceNow)
            tapped.insert(cta)
        }
    }

    // After a relaunch: wait for `expected`, failing on any `forbidden` screen.
    func awaitScreen(_ expected: Key, forbidden: [Key], at step: String) throws {
        let deadline = Date().addingTimeInterval(Bound.relaunch)
        while true {
            try requireForeground(step)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw GateFailure("\(expected.rawValue) was not shown within \(Int(Bound.relaunch)) s at \(step); \(seen())")
            }
            awaitAnyKnown(remaining)
            try requireForeground(step)
            let visible = try visibleKeys()
            try failIfError(visible, at: step)
            if let wrong = forbidden.first(where: visible.contains) {
                throw GateFailure("\(wrong.rawValue) was shown at \(step); \(seen())")
            }
            if visible.contains(expected) { return }
        }
    }

    // The create screen restores the saved name asynchronously; the last value
    // read is what the caller compares.
    func restoredName(matching accepts: @escaping (String?) -> Bool) throws -> String? {
        let fields = app.textFields
        guard fields.count == 1 else {
            throw GateFailure("the create-identity screen shows \(fields.count) text fields after the relaunch, not one; \(seen())")
        }
        let field = fields.element(boundBy: 0)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in accepts(field.value as? String) }, object: nil)
        _ = XCTWaiter.wait(for: [restored], timeout: Bound.restore)
        return field.value as? String
    }

    // Whether the field was empty, never what it holds.
    func failRestored(_ shown: String?) {
        XCTFail("restored name differs: the field is \(shown?.isEmpty ?? true ? "empty" : "not empty") after \(Int(Bound.restore)) s; \(seen())")
    }

    // The held error shows only once this run's create CTA was tapped, and
    // turns that CTA into Retry: at a relaunch it is a wrong screen.
    func awaitTerminalAfterRelaunch(_ terminal: Terminal, at step: String) throws {
        switch terminal {
        case .setupHeld:
            try awaitScreen(.create, forbidden: [.welcome, .setupHeld, .map], at: step)
        case .map:
            try awaitScreen(.map, forbidden: [.welcome, .create, .setupHeld], at: step)
        }
    }
}

final class LaunchGateUITests: XCTestCase {
    // Fresh install: onboarding offline ends on a terminal screen, and a cold
    // relaunch returns to it with the display name the first run saved.
    @MainActor
    func testFreshInstallThenColdRelaunch() throws {
        continueAfterFailure = false
        let journey = try Journey()
        try journey.launch("the first launch")
        let (terminal, name) = try journey.onboard()
        print("LAUNCH-GATE-TERMINAL \(terminal.rawValue)")
        try journey.relaunchCold()
        try journey.awaitTerminalAfterRelaunch(terminal, at: "the cold relaunch")
        if terminal == .setupHeld {
            let restored = try journey.restoredName { $0 == name }
            if restored != name { journey.failRestored(restored) }
        }
    }

    // The previous release's build, onboarded offline before the candidate is
    // installed over it. The runner carries the terminal and the salted digest
    // to testUpgradedCandidateRelaunch.
    @MainActor
    func testOnboardUpgradeSource() throws {
        continueAfterFailure = false
        guard let salt = environment("GATE_NAME_SALT") else {
            throw GateFailure("no GATE_NAME_SALT was passed")
        }
        let journey = try Journey()
        try journey.launch("the upgrade source's first launch")
        let (terminal, name) = try journey.onboard()
        print("LAUNCH-GATE-TERMINAL \(terminal.rawValue)")
        print("LAUNCH-GATE-NAME-DIGEST \(saltedDigest(name, salt: salt))")
        journey.app.terminate()
    }

    // The candidate, installed over the upgrade source with its data kept:
    // the same terminal screen, never onboarding from the start, and the name
    // the upgrade source saved.
    @MainActor
    func testUpgradedCandidateRelaunch() throws {
        continueAfterFailure = false
        guard let salt = environment("GATE_NAME_SALT"),
              let expected = environment("GATE_EXPECT_NAME_DIGEST"),
              let terminal = environment("GATE_EXPECT_TERMINAL").flatMap(Terminal.init(rawValue:))
        else {
            throw GateFailure("GATE_NAME_SALT, GATE_EXPECT_NAME_DIGEST and GATE_EXPECT_TERMINAL must all be passed")
        }
        let journey = try Journey()
        try journey.launch("the upgraded candidate's first launch")
        try journey.awaitTerminalAfterRelaunch(terminal, at: "the upgraded candidate's first launch")
        if terminal == .setupHeld {
            let restored = try journey.restoredName { shown in shown.map { saltedDigest($0, salt: salt) } == expected }
            if restored.map({ saltedDigest($0, salt: salt) }) != expected { journey.failRestored(restored) }
        }
    }
}
