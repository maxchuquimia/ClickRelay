import Foundation

/// One element a script step could mean, as plain data (no AX), so matching
/// can be tested without permissions.
nonisolated struct MatchCandidate: Sendable, Equatable {
    var role: String
    var subrole: String?
    var title: String?
    var label: String?
    var value: String?
    var identifier: String?
    var enabled: Bool = true
    var interactive: Bool = true
    /// Which window it's in, 0 being frontmost (menus are 0). Ties go to the
    /// frontmost window.
    var rank: Int = 0

    /// One line for the model or a refusal: `AXButton "Export…" (id export, disabled)`.
    var line: String {
        var parts = [role]
        let name = [title, label].compactMap { $0 }.first { !$0.isEmpty }
        if let name { parts.append("\"\(ElementMatcher.clip(name))\"") }
        if let label, !label.isEmpty, label != name { parts.append("label \"\(ElementMatcher.clip(label))\"") }
        if let value, !value.isEmpty { parts.append("value \"\(ElementMatcher.clip(value))\"") }
        if let identifier, !identifier.isEmpty { parts.append("id \(ElementMatcher.clip(identifier))") }
        if !enabled { parts.append("disabled") }
        if rank > 0 { parts.append("in window \(rank + 1)") }
        return parts.joined(separator: " ")
    }
}

/// How a step's element was found, for the audit log and the run summary.
nonisolated enum MatchMethod: String, Sendable {
    case identifier, exact, partial, model
}

nonisolated enum MatchResult: Equatable, Sendable {
    case unique(Int, MatchMethod)
    /// Several fit equally well (indices into the candidates).
    case ambiguous([Int])
    case noMatch
}

/// What `pick` settled on, after the on-device model if it was needed.
nonisolated enum PickResult: Equatable, Sendable {
    case found(Int, MatchMethod)
    /// Nothing fits. `closest` are a few candidates to name in the refusal;
    /// `note` says why the model didn't help, if it was asked.
    case notFound(closest: [Int], note: String?)
}

/// Finds a script step's element among the candidates. Deterministic tiers
/// first (identifier, exact text, partial text), and the on-device model only
/// when they leave nothing or a tie. The model only ever picks one of the
/// candidates (or none); it can't invent an element or an action.
nonisolated enum ElementMatcher {
    /// Most candidates shown to the model. Its context window is small.
    static let modelShortlist = 40

    static func match(_ target: ElementTarget, in candidates: [MatchCandidate]) -> MatchResult {
        let pool = candidates.indices.filter { index in
            let candidate = candidates[index]
            if let role = target.role, !roleMatches(role, candidate) { return false }
            if let enabled = target.enabled, candidate.enabled != enabled { return false }
            return true
        }
        if let identifier = target.identifier {
            let wanted = normalise(identifier)
            var hits = pool.filter { candidates[$0].identifier.map(normalise) == wanted }
            if hits.count > 1 {
                let narrowed = hits.filter { textMatches(target, candidates[$0], exact: true) }
                if !narrowed.isEmpty { hits = narrowed }
            }
            if !hits.isEmpty { return resolve(hits, candidates, .identifier) }
            // A changed identifier can still be found by its text.
        }
        let hasText = target.title != nil || target.label != nil || target.value != nil
        guard hasText else {
            // Role only: fine when it's the only one of its kind.
            if target.identifier == nil, target.role != nil, !pool.isEmpty {
                return resolve(pool, candidates, .exact)
            }
            return .noMatch
        }
        let exact = pool.filter { textMatches(target, candidates[$0], exact: true) }
        if !exact.isEmpty { return resolve(exact, candidates, .exact) }
        let partial = pool.filter { textMatches(target, candidates[$0], exact: false) }
        if !partial.isEmpty { return resolve(partial, candidates, .partial) }
        return .noMatch
    }

    /// `match`, then the model for a tie or (with `allowModel`) a miss.
    static func pick(_ target: ElementTarget, step: String, in candidates: [MatchCandidate],
                     allowModel: Bool, chooser: any ElementChooser) async -> PickResult {
        let shortlist: [Int]
        switch match(target, in: candidates) {
        case .unique(let index, let method):
            return .found(index, method)
        case .ambiguous(let tied):
            shortlist = Array(tied.prefix(modelShortlist))
        case .noMatch:
            let ranked = rank(target, candidates)
            guard allowModel, !ranked.isEmpty else {
                return .notFound(closest: Array(ranked.prefix(5)), note: nil)
            }
            shortlist = Array(ranked.prefix(modelShortlist))
        }
        let request = ChooserRequest(step: step, options: shortlist.map { candidates[$0].line })
        switch await chooser.choose(request) {
        case .picked(let option) where shortlist.indices.contains(option):
            return .found(shortlist[option], .model)
        case .picked, .noMatch:
            return .notFound(closest: Array(shortlist.prefix(5)), note: nil)
        case .unavailable(let reason):
            return .notFound(closest: Array(shortlist.prefix(5)), note: reason)
        }
    }

    /// Candidates worth showing the model when nothing matched: the right role
    /// (if given), most similar first, interactive before static.
    static func rank(_ target: ElementTarget, _ candidates: [MatchCandidate]) -> [Int] {
        let wanted = tokens([target.title, target.label, target.value, target.identifier, target.hint])
        let scored = candidates.indices.compactMap { index -> (Int, Double)? in
            let candidate = candidates[index]
            if let role = target.role, !roleMatches(role, candidate) { return nil }
            let have = tokens([candidate.title, candidate.label, candidate.value, candidate.identifier])
            guard !have.isEmpty else { return nil }
            var score = wanted.isEmpty ? 0 : Double(wanted.intersection(have).count) / Double(wanted.count)
            if candidate.interactive { score += 0.05 }
            if !candidate.enabled { score -= 0.05 }
            score -= Double(candidate.rank) * 0.01
            return (index, score)
        }
        // Keep document order among equals (reading order is a useful hint).
        return scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map { $0.element.0 }
    }

    // MARK: - Pieces

    private static func resolve(_ hits: [Int], _ candidates: [MatchCandidate], _ method: MatchMethod) -> MatchResult {
        guard let front = hits.map({ candidates[$0].rank }).min() else { return .noMatch }
        var best = hits.filter { candidates[$0].rank == front }
        if best.count > 1 {
            let enabled = best.filter { candidates[$0].enabled }
            if !enabled.isEmpty { best = enabled }
        }
        if best.count > 1 {
            let interactive = best.filter { candidates[$0].interactive }
            if !interactive.isEmpty { best = interactive }
        }
        return best.count == 1 ? .unique(best[0], method) : .ambiguous(best)
    }

    static func roleMatches(_ role: String, _ candidate: MatchCandidate) -> Bool {
        let wanted = squash(role)
        return squash(candidate.role) == wanted || candidate.subrole.map(squash) == wanted
    }

    /// Every text field the target gives must match. Title and label are
    /// interchangeable (apps put a button's name in either).
    private static func textMatches(_ target: ElementTarget, _ candidate: MatchCandidate, exact: Bool) -> Bool {
        func fits(_ wanted: String, _ have: String?) -> Bool {
            guard let have else { return false }
            let a = normalise(wanted), b = normalise(have)
            guard !a.isEmpty, !b.isEmpty else { return false }
            return exact ? a == b : b.contains(a)
        }
        let names = [candidate.title, candidate.label]
        if let title = target.title, !names.contains(where: { fits(title, $0) }) { return false }
        if let label = target.label, !names.contains(where: { fits(label, $0) }) { return false }
        if let value = target.value, !fits(value, candidate.value) { return false }
        return target.title != nil || target.label != nil || target.value != nil
    }

    /// Case, spacing and trailing "…" / ":" don't count: "Export…" is "export".
    static func normalise(_ text: String) -> String {
        var result = text.lowercased()
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while result.hasSuffix("...") { result.removeLast(3) }
        while result.hasSuffix(":") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func squash(_ role: String) -> String {
        role.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func tokens(_ texts: [String?]) -> Set<String> {
        var set = Set<String>()
        for text in texts.compactMap({ $0 }) {
            for word in normalise(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                set.insert(String(word))
            }
        }
        return set
    }

    static func clip(_ text: String, to length: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }
}
