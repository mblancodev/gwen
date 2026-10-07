// Intelligent insert: fit pasted dictation to AX caret neighbors (caps, spaces, punct).
import AppKit

/// Adjust `text` for what sits before/after the caret (or selection). Pure — easy to reason about / mirror in tests.
func smartInsert(_ text: String, before: String, after: String) -> String {
    guard !text.isEmpty else { return text }
    var body = trimEdgeSpaces(text)
    guard !body.isEmpty else { return "" }

    // Punctuation clashes: don't paste a second stopper / comma against one already there.
    body = stripClashingLeadPunct(body, before: before)

    if isSentenceStart(before) {
        body = capitalizeFirst(body)
    } else if isMidSentence(before) {
        body = lowercaseFirstWord(body)
    }

    var out = ""
    if needsLeadingSpace(before: before, body: body) { out += " " }
    out += body
    if needsTrailingSpace(body: body, after: after) { out += " " }
    return out
}

/// Characters around the caret (or selection) via Accessibility. Nil when the field won't expose value/range.
func axCaretContext(_ el: AXUIElement?) -> (before: String, after: String)? {
    guard let el else { return nil }
    var val: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &val) == .success,
          let full = val as? String, full.count <= 50_000 else { return nil }
    let ns = full as NSString
    var sel: AnyObject?, range = CFRange(location: ns.length, length: 0)
    if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sel) == .success,
       let sel, AXValueGetValue(sel as! AXValue, .cfRange, &range) {
        // ok
    } else {
        range = CFRange(location: ns.length, length: 0)
    }
    let loc = max(0, min(Int(range.location), ns.length))
    let end = max(loc, min(loc + max(Int(range.length), 0), ns.length))
    let before = ns.substring(to: loc)
    let after = ns.substring(from: end)
    return (String(before.suffix(120)), String(after.prefix(80)))
}

// MARK: - rules

private let sentenceEnd = CharacterSet(charactersIn: ".?!…")
private let closers = CharacterSet(charactersIn: "\"'”»)]}›")
private let openers = CharacterSet(charactersIn: "\"'“«([{‹¿¡")
private let leadPunct = CharacterSet(charactersIn: ",.;:!?…)]}”»\"'")

private func isSentenceStart(_ before: String) -> Bool {
    let t = before.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return true }
    if before.hasSuffix("\n") || before.hasSuffix("\r") { return true }
    // Only openers (or openers + space): start of content inside (, ", ¿…
    if t.unicodeScalars.allSatisfy({ openers.contains($0) || CharacterSet.whitespaces.contains($0) }) {
        return true
    }
    // Strip trailing closers/spaces after a sentence end: `done." ` / `done.)`
    var i = t.endIndex
    while i > t.startIndex {
        let p = t.index(before: i)
        let ch = t[p]
        if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) })
            || ch.unicodeScalars.allSatisfy({ closers.contains($0) }) {
            i = p
            continue
        }
        return ch.unicodeScalars.allSatisfy({ sentenceEnd.contains($0) })
    }
    return true
}

private func isMidSentence(_ before: String) -> Bool {
    !isSentenceStart(before) && before.contains(where: { $0.isLetter || $0.isNumber })
}

private func needsLeadingSpace(before: String, body: String) -> Bool {
    guard let last = before.last else { return false }
    guard let first = body.first else { return false }
    if last == " " || last == "\t" || last == "\n" || last == "\r" { return false }
    if first.unicodeScalars.allSatisfy({ leadPunct.contains($0) }) { return false }
    if first.unicodeScalars.allSatisfy({ openers.contains($0) }) { return false }
    if last.unicodeScalars.allSatisfy({ openers.contains($0) }) { return false }
    // After a letter/digit/closer, insert needs a gap before a word.
    return last.isLetter || last.isNumber || last.unicodeScalars.allSatisfy({ closers.contains($0) })
}

private func needsTrailingSpace(body: String, after: String) -> Bool {
    guard let first = after.first else { return false }
    guard let last = body.last else { return false }
    if first == " " || first == "\t" || first == "\n" || first == "\r" { return false }
    if first.unicodeScalars.allSatisfy({ leadPunct.contains($0) }) { return false }
    if last.unicodeScalars.allSatisfy({ openers.contains($0) }) { return false }
    return first.isLetter || first.isNumber
}

private func stripClashingLeadPunct(_ body: String, before: String) -> String {
    guard let first = body.first else { return body }
    let tip = before.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let prev = tip.last else { return body }
    // "word." + ". More" → "More" ; "word" + ", and" stays; "word " + ".x" handled by caps
    let clash = CharacterSet(charactersIn: ".…,;:")
    if prev.unicodeScalars.allSatisfy({ clash.contains($0) })
        && first.unicodeScalars.allSatisfy({ clash.contains($0) }) {
        return String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return body
}

private func capitalizeFirst(_ s: String) -> String {
    guard let f = s.first else { return s }
    if f.isLetter { return String(f).uppercased() + s.dropFirst() }
    // Leading opener: capitalize the first letter after ¿¡"'«(
    var chars = Array(s)
    for i in chars.indices where chars[i].isLetter {
        chars[i] = Character(String(chars[i]).uppercased())
        break
    }
    return String(chars)
}

private func lowercaseFirstWord(_ s: String) -> String {
    // Keep acronyms (AI, OK) and single-letter I.
    let idx = s.firstIndex(where: { $0.isLetter }) ?? s.startIndex
    guard idx < s.endIndex else { return s }
    let rest = s[idx...]
    let word = rest.prefix(while: { $0.isLetter })
    if word == "I" { return s }
    if word.count >= 2 && word.allSatisfy({ $0.isUppercase }) { return s }
    var chars = Array(s)
    let i = s.distance(from: s.startIndex, to: idx)
    chars[i] = Character(String(chars[i]).lowercased())
    return String(chars)
}

private func trimEdgeSpaces(_ s: String) -> String {
    // Trim spaces/tabs on the ends only; keep newlines (paragraph dictation).
    var a = s
    while a.first == " " || a.first == "\t" { a = String(a.dropFirst()) }
    while a.last == " " || a.last == "\t" { a = String(a.dropLast()) }
    return a
}
