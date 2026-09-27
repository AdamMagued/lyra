import Foundation

/// Pure deterministic parser translating normalised transcripts into typed `LyraCommand`s.
///
/// Two things matter beyond simple keyword matching:
///
/// **Ordering encodes a safety policy.** `stop` beats everything. If a user says
/// "stop, click" because the cursor is doing something wrong, the system must halt,
/// not click. Matching is therefore evaluated in priority order and returns on first
/// hit, never by scoring all rules and taking the best.
///
/// **Ambiguous input does nothing.** Returning `.unrecognized` is a correct outcome.
/// A parser that guesses turns a misheard word into an unintended action on someone
/// else's document, which for an accessibility tool is the worst possible failure.
public struct CommandParser: Sendable {

    public init() {}

    /// Normalises spoken text: lowercased, punctuation stripped, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let cleaned = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// Parses a raw transcript into a command.
    public func parse(_ rawText: String) -> LyraCommand {
        Self.parse(rawText)
    }

    /// Static form, so command parsing can be exercised without constructing a parser.
    public static func parse(_ rawText: String) -> LyraCommand {
        let normalized = normalize(rawText)
        guard !normalized.isEmpty else { return .unrecognized(rawText) }

        let words = Set(normalized.split(separator: " ").map(String.init))
        let has = { (word: String) in words.contains(word) }
        let isExactly: (String...) -> Bool = { options in options.contains(normalized) }

        // 1. Safety first. Anything that reads as "stop" wins outright.
        if has("stop") || has("off") || has("pause") || has("halt")
            || has("freeze") || has("disable")
            || isExactly("cancel tracking", "turn off", "shut off") {
            return .stopTracking
        }

        // 2. Explicit cancellation of the current selection.
        if isExactly("cancel", "never mind", "nevermind", "clear", "dismiss", "forget it") {
            return .cancel
        }

        // 3. Confirmation round-trip. Kept narrow: bare "no" is too easy to mishear
        //    out of ordinary speech to be safe as a global rule.
        if isExactly("yes", "confirm", "go ahead", "do it", "affirmative") {
            return .confirm
        }
        if isExactly("no", "deny", "abort", "dont", "do not") {
            return .deny
        }

        // 4. Selection adjustment, for when gaze picked the wrong thing.
        if isExactly("next", "next one", "next target", "other", "the other one", "not this") {
            return .nextTarget
        }
        if isExactly("previous", "previous one", "back one", "last one") {
            return .previousTarget
        }

        // 5. Magnification for fine picking.
        if isExactly("zoom in", "zoom", "magnify", "closer") { return .zoomIn }
        if isExactly("zoom out", "unzoom", "back out") { return .zoomOut }

        // 6. Reveal what is pickable.
        if isExactly("show targets", "show labels", "what can i click", "show options") {
            return .showTargets
        }
        if isExactly("hide targets", "hide labels", "hide options") {
            return .hideTargets
        }

        // 7. Activation. Checked after the more specific multi-word forms below.
        if isExactly("double click", "double tap") { return .doubleClick }
        if isExactly("right click", "secondary click", "context menu") { return .rightClick }
        if isExactly("undo", "undo that") { return .undo }

        if isExactly("click", "left click", "tap", "pick", "select", "press", "choose",
                     "activate", "hit", "do this", "click this", "pick this", "this one") {
            return .activate
        }

        // 8. Activation as the trailing verb of a longer phrase, e.g. "click the button".
        //    Requires an explicit object so ordinary conversation does not trigger it.
        if words.contains("click") || words.contains("pick") || words.contains("select") {
            let pronounObjects: Set<String> = [
                "this", "that", "it", "there", "here", "one", "button", "thing"
            ]
            if !words.isDisjoint(with: pronounObjects) {
                return .activate
            }
        }

        // 9. Start tracking. Last, because "cursor" is a weak signal that can appear
        //    inside unrelated speech.
        if isExactly("cursor", "start", "start tracking", "track", "begin",
                     "start cursor", "turn on", "resume") {
            return .startTracking
        }

        return .unrecognized(rawText)
    }
}
