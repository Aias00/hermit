//
//
//
// iOSTextInput.swift: code necessary to support UITextInput, almost everything
// is here, with the exception of `insertText` which is in iOSTerminalView.
//
// The system will invoke either methods in this file, or `insertText` and will
// modify the markedText property during input to reflect the state of the data
// that needs to be removed or wiped.
//
// 1. First, regular typing, that should work.
//
// Input systems:
// 1. With a keyboard input system that supports composed input (like Chinese,
//    Simplified Pinyin), try typing "d", and then it should show a bar of
//    completions, and once selected, it should insert the full result.
// 2. With the above, attempt entering "dddd" and select the first instance,
//    it should insert "点点滴滴"
// 3. Bonus points, try the other Chinese input methods (they differ in the
//    way the data is entered).
//
// Dictation:
// 1. Enable dictation in the app, and then say the word "Hello world", and
//    then tap the microphone again.
// 2. The above should show "Hello world", with no spaces before it (a common
//    bug I fought when inserText was not tracking the markedText region was
//    that it would insert 11 spaces instead - if you get this, this is a
//    sign that the logic for the marking is wrong).
// 3. Dictate "Hello world" once, and then "Hello world" again, it should work,
//    if not, it is possible that the internal state of the selection has gone
//    out of sync again with the dictation system.
//
// Bonus tests, but these should just be straight forward:
// 1. Inserting an emoji from the keyboard emoji should work
// 2. Inserting arabic characters, pick "م" and then "ا" should render "ما"

//
// Ideas:
//   setMarkedText could show an overlay of the text being composed, so that
//   there is a visual cue of what is going on for foreign language input users
//
//  Created by Miguel de Icaza on 1/28/21.
//

//
// Observations 2025-05-27 GAR:
// 1. Dictation was not working. Seems that root cause we that the textInputStorage was being cleared
//    when the dictation was in progress and it could not update its hypothesis. Furthermore
//    the replace function was not sending changes to the terminal. This prevented the user
//    from seeing the incremental updates.
// 2. The dictation seems to always invoke insertText with an empty string and a space before it calls
//    insertDictationResult. This is not ideal, first sentences will always have a space before them. This
//    sequence can be detected in the terminal and handled as desired.
//

#if os(iOS) || os(visionOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

/// UITextInput Log capability
@inline(__always)
internal func uitiLog (_ message: @autoclosure () -> String) {
    guard TerminalView.textInputDebugEnabled else { return }
    TerminalView.textInputLogCounter += 1
    print ("UITextInput[\(TerminalView.textInputLogCounter)]: \(message())")
}

extension TerminalView: UITextInput {    
    func trace (function: String = #function)  {
        uitiLog ("TRACE: \(function)")
    }

    func textInputStateDescription() -> String {
        let marked = _markedTextRange?.description ?? "nil"
        let language = textInputMode?.primaryLanguage ?? "nil"
        return "storage:\(textInputStorage.debugDescription) marked:\(marked) selected:\(_selectedTextRange.description) lang:\(language)"
    }

    private func clampOffset(_ offset: Int) -> Int {
        return max(0, min(offset, textInputStorage.count))
    }

    private func coerceTextPosition(_ position: UITextPosition) -> TextPosition? {
        guard let tp = position as? TextPosition else { return nil }
        let clamped = clampOffset(tp.offset)
        return clamped == tp.offset ? tp : TextPosition(offset: clamped)
    }

    private func coerceTextRange(_ range: UITextRange) -> TextRange? {
        if let r = range as? TextRange {
            let start = clampOffset(r.startPosition.offset)
            let end = clampOffset(r.endPosition.offset)
            if start == r.startPosition.offset && end == r.endPosition.offset {
                return r
            }
            return TextRange(from: TextPosition(offset: start), to: TextPosition(offset: end))
        }

        guard let start = coerceTextPosition(range.start),
              let end = coerceTextPosition(range.end) else {
            return nil
        }
        return TextRange(from: start, to: end)
    }

    /// Brackets a change to `textInputStorage`. The input delegate hears about
    /// it only when the change did not come from the input system: telling a
    /// keyboard that the text changed under it while it is the one changing
    /// it reads as the user editing behind its back. 豆包's voice input ends
    /// its session on that — on the first correction it made to text it had
    /// already streamed in, so a dictated sentence stopped mid-way.
    /// `force` is for a reset the keyboard did not ask for (Return clearing
    /// the buffer) even when it happens inside one of its calls.
    func beginTextInputEdit(force: Bool = false) {
        uitiLog("beginTextInputEdit \(textInputStateDescription())")
        guard force || inputSystemEditDepth == 0 else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
    }

    func endTextInputEdit(force: Bool = false) {
        defer { uitiLog("endTextInputEdit \(textInputStateDescription())") }
        guard force || inputSystemEditDepth == 0 else { return }
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    public func text(in range: UITextRange) -> String? {
        guard let r = range as? TextRange else { return nil }

        if r.isEmpty {
            uitiLog("text(in:\(r)) -> \"\" \(textInputStateDescription())")
            return ""
        } else {
            let result = String(textInputStorage[r.fullRange(in: textInputStorage)])
            uitiLog("text(in:\(r)) -> \(result.debugDescription) \(textInputStateDescription())")
            return result
        }        
    }
    
    public func replace(_ range: UITextRange, withText text: String) {
        inputSystemEditDepth += 1
        defer { inputSystemEditDepth -= 1 }
        phantomReinsertPending = false
        guard let r = range as? TextRange else { return }

        guard _markedTextRange == nil else { return }
        uitiLog ("replace(range:\(r), withText:\(text.debugDescription)) \(textInputStateDescription())")

        beginTextInputEdit()

        // Send the edits to the terminal
        // Delete the old by sending as many backspaces as needed
        let oldText = textInputStorage[r.fullRange(in: textInputStorage)]
        if !isAutoPeriodReplacement(text) {
            pendingAutoPeriodDeleteWasSpace = false
        }
        var replacementText = text
        if let normalized = normalizedAutoPeriodReplacementText(text, oldText: oldText, rangeToReplace: r) {
            replacementText = normalized
        }
        let backspaces = remoteBackspaceCount(for: oldText)
        for _ in 0..<backspaces {
            self.send ([0x7f])
        }
        self.send (txt: replacementText)

        let insertionIndex = r.startPosition.offset
        textInputStorage.replaceSubrange(r.fullRange(in: textInputStorage), with: replacementText)
        if r.endPosition.offset <= _selectedTextRange.startPosition.offset {
            let selectionOffset = _selectedTextRange.startPosition.offset - insertionIndex
            let newSelectionOffset = selectionOffset - r.length + replacementText.count
            let newSelectionIndex = newSelectionOffset + insertionIndex
            _selectedTextRange = TextRange(from: TextPosition(offset:newSelectionIndex), 
                                            to: TextPosition(offset: newSelectionIndex + _selectedTextRange.length))
        } else if r.startPosition.offset >= _selectedTextRange.endPosition.offset {
            // NOOP
        } else {
            let insertionEndPosition = TextPosition(offset:insertionIndex + replacementText.count)            
            _selectedTextRange = TextRange(from: insertionEndPosition,  to: insertionEndPosition)
        }

        endTextInputEdit()
    }

    /*
        If the text range has a length, it indicates the currently selected text. 
        If it has zero length, it indicates the caret (insertion point). 
        If the text-range object is nil, it indicates that there is no current selection.
    */
    public var selectedTextRange: UITextRange? {
        get {
            return _selectedTextRange
        }
        set {
            guard let newValue else {
                uitiLog("selectedTextRange -> nil (ignored) \(textInputStateDescription())")
                return
            }
            guard let nv = coerceTextRange(newValue) else {
                uitiLog("selectedTextRange -> unsupported range \(type(of: newValue)) \(textInputStateDescription())")
                return
            }
            let isSame = _selectedTextRange.startPosition.offset == nv.startPosition.offset &&
                _selectedTextRange.endPosition.offset == nv.endPosition.offset
            if isSame {
                return
            }
            // No selectionWillChange/DidChange here: whoever assigns this IS
            // the input system (or the space-bar trackpad it drives), and the
            // input delegate is only for changes it did not make — see
            // `beginTextInputEdit()`. UIKit sets it on every delete it carries
            // out for a third-party keyboard (select the two characters before
            // the caret, delete both, re-insert the first).
            _selectedTextRange = nv
            uitiLog ("selectedTextRange -> \(_selectedTextRange)")
        }
    }
    
    /*
        If there is no marked text, the value of the property is nil. 
        Marked text is provisionally inserted text that requires user confirmation; it occurs in multistage text input. 
        The current selection, which can be a caret or an extended range, always occurs within the marked text.
    */
    public var markedTextRange: UITextRange? {
        get {
            return _markedTextRange
        }
        set {
            _markedTextRange = newValue as? TextRange
            uitiLog("markedTextRange -> \(_markedTextRange)")
        }
    }
    
    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get {
            return _markedTextStyle
        }
        set {
            _markedTextStyle = newValue
        }
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputSystemEditDepth += 1
        defer { inputSystemEditDepth -= 1 }
        uitiLog("setMarkedText(\(markedText?.debugDescription ?? "nil"), selectedRange:\(selectedRange)) \(textInputStateDescription())")
        phantomReinsertPending = false

        let rangeToReplace = _markedTextRange ?? _selectedTextRange
        let rangeStartPosition = rangeToReplace.startPosition

        beginTextInputEdit()

        if let newText = markedText {
            textInputStorage.replaceSubrange(rangeToReplace.fullRange(in: textInputStorage), with: newText)
            // Figure out the new selection range
            let rangeStartIndex = rangeStartPosition.offset
            let newTextRange = Range(selectedRange, in: newText)!
            let newTextRangeOffset = newText.distance(from: newText.startIndex, to: newTextRange.lowerBound)
            let newTextRangeLength = newText.distance(from: newTextRange.lowerBound, to: newTextRange.upperBound)

            let selectionStartIndex = rangeStartIndex + newTextRangeOffset
            _markedTextRange = TextRange(from: rangeStartPosition, maxOffset: newText.count, in: textInputStorage) 
            _selectedTextRange = TextRange(from: TextPosition(offset: selectionStartIndex),
                                           to: TextPosition(offset: selectionStartIndex + newTextRangeLength))
        } else {
            textInputStorage.removeSubrange(rangeToReplace.fullRange(in: textInputStorage))
            _markedTextRange = nil
            _selectedTextRange = TextRange(from: rangeStartPosition, to: rangeStartPosition)
        }

        endTextInputEdit()
        updateIMECompositionOverlay()
    }

    /// Show/update/hide the composition overlay at the cursor position,
    /// mirroring `updateCursorPosition()`'s geometry. Composing text must
    /// never reach the terminal buffer/remote until committed (that's the
    /// whole point of marked text), so it can't just be `feed()`-ed in —
    /// this paints it as a small underlined label instead, removed the
    /// moment composition ends (commit via `unmarkText`, or cancellation).
    /// Moves the EXISTING terminal caret (`caretView`) to the end of that
    /// text as it grows — not a second, separate cursor — so there's still
    /// exactly one cursor on screen, just one that tracks composition
    /// instead of sitting frozen at the pre-composition position. Left
    /// exactly where composition put it once composition ends — see the
    /// guard branch below for why that's deliberate, not a missing reset.
    ///
    /// Deliberately always the END of the composing text, not wherever
    /// `_selectedTextRange` claims the insertion point is: phonetic IMEs
    /// (Pinyin, Zhuyin, romaji) replace the whole marked string on every
    /// keystroke and candidate-bar paging can report a stale/reset
    /// selection (e.g. collapsed to the start) without the user actually
    /// repositioning anything, which made the caret jitter back to the
    /// front of the composition mid-typing when this tracked that value.
    /// True while composing text is actually rendered on screen — the marked
    /// range and the overlay showing it both exist. `updateCursorPosition()`
    /// checks this to stay out of the composition's way; see the comment
    /// there. Both halves matter: a marked range with no label (composition
    /// just cancelled, label already torn down) has no overlay geometry to
    /// defer to.
    var hasActiveIMEComposition: Bool {
        _markedTextRange != nil && imeCompositionLabel != nil
    }

    func updateIMECompositionOverlay() {
        guard let markedRange = _markedTextRange,
              let composingText = text(in: markedRange), !composingText.isEmpty else {
            imeCompositionLabel?.removeFromSuperview()
            imeCompositionLabel = nil
            // Composition ended (commit or cancel) — do NOT call
            // updateCursorPosition() here. The committed text was just
            // `send()`-ed to the remote and hasn't been echoed back yet, so
            // the terminal buffer's OWN cursor (buffer.x/y) is still sitting
            // wherever it was BEFORE this composition started — snapping to
            // it now visibly yanks the caret backwards (reported: cursor
            // jumps to the front right after finishing a word). Leaving
            // caretView exactly where composition left it (the end of the
            // just-committed text) is the visually correct state; the
            // normal feed()-driven redraw already calls
            // updateCursorPosition() once the real echo lands, same as any
            // other typed input.
            return
        }
        let label: UILabel
        if let existing = imeCompositionLabel {
            label = existing
        } else {
            label = UILabel()
            label.numberOfLines = 1
            imeCompositionLabel = label
            addSubview(label)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: nativeForegroundColor
        ]
        label.attributedText = NSAttributedString(string: composingText, attributes: attributes)
        label.sizeToFit()

        let buffer = terminal.displayBuffer
        let vy = buffer.yBase + buffer.y
        let doublePosition = buffer.lines[vy].renderMode == .single ? 1.0 : 2.0
        let origin = CGPoint(
            x: cellDimension.width * doublePosition * CGFloat(buffer.x),
            y: cellDimension.height * CGFloat(buffer.y + buffer.yBase))
        label.frame.origin = origin

        let fullWidth = (composingText as NSString).size(withAttributes: attributes).width
        if let caretView {
            caretView.frame.origin = CGPoint(x: origin.x + fullWidth, y: origin.y)
            if caretView.superview == nil { addSubview(caretView) }
        }
    }

    func resetInputBuffer (_ loc: String = #function)
    {
        uitiLog("resetInputBuffer() from \(loc) \(textInputStateDescription())")
        beginTextInputEdit(force: true)
        pendingAutoPeriodDeleteWasSpace = false
        textInputStorage = ""
        _selectedTextRange = TextRange (from: TextPosition(offset: 0), to: TextPosition(offset: 0))
        _markedTextRange = nil
        primePhantomInputPrefix()
        endTextInputEdit(force: true)
        updateIMECompositionOverlay()
    }

    /// Park one phantom character in front of the caret so the system keyboard
    /// keeps repeating the delete key.
    ///
    /// UIKit does not ask `hasText` on every repeat tick. Before each tick it
    /// measures the document — the position one character back from the caret —
    /// and stops the moment that range comes back empty. In a terminal that
    /// range is empty far more often than there is genuinely nothing to delete,
    /// because `textInputStorage` only shadows what was typed *here* since the
    /// last Return. It is empty for everything the REMOTE put on the line: a
    /// reattached session holding a half-written command, a paste the shell
    /// echoed back, a history entry recalled with the up arrow. Patch (10) made
    /// `hasText` always true, which was necessary but not sufficient — the
    /// geometry still said "caret at the start of an empty document", so
    /// holding delete over remote-owned text deleted exactly one character and
    /// then went dead, while holding it over text typed on the same line worked
    /// fine. That is what made the bug read as random.
    ///
    /// One character is enough, and one is deliberately all we keep: a longer
    /// run would give the accelerated "delete by word" mode something to chew
    /// through, and each of those characters would bill the remote for a
    /// backspace it never received. Deleting the phantom is indistinguishable
    /// from the old empty-buffer path — one `deleteBackward()`, one backspace
    /// byte — and what that byte does is the remote's decision, not ours.
    ///
    /// Only ever primes an *empty* buffer, so it cannot shift an offset UIKit
    /// is still holding onto for real text.
    func primePhantomInputPrefix() {
        guard isFirstResponder, _markedTextRange == nil, textInputStorage.isEmpty else { return }
        textInputStorage = String(TerminalView.phantomInputCharacter)
        let afterPhantom = TextPosition(offset: textInputStorage.count)
        _selectedTextRange = TextRange(from: afterPhantom, to: afterPhantom)
    }

    /// How many backspaces a stretch of the shadow buffer is worth on the remote.
    ///
    /// Phantom characters (see ``primePhantomInputPrefix()``) were never sent
    /// anywhere, so they owe the remote nothing — but a delete that lands
    /// entirely on them still has to send one, exactly as the old empty-buffer
    /// path did, or holding delete over remote-owned text goes dead again. An
    /// empty range still sends nothing: that is an insertion, not a deletion.
    func remoteBackspaceCount<S: StringProtocol>(for text: S) -> Int {
        if text.isEmpty { return 0 }
        return max(1, text.filter { $0 != TerminalView.phantomInputCharacter }.count)
    }

    public func unmarkText() {
        inputSystemEditDepth += 1
        defer { inputSystemEditDepth -= 1 }
        uitiLog("unmarkText() \(textInputStateDescription())")
        phantomReinsertPending = false
        if let previouslyMarkedRange = _markedTextRange {
            // Ensure that multi-char input (Chinese-Japanese keyboards) works:
            if let previouslyMarkedText = text(in: previouslyMarkedRange) {
                if previouslyMarkedText.count > 0 {
                    uitiLog("unmarkText commit:\(previouslyMarkedText.debugDescription) range:\(previouslyMarkedRange)")
                    insertText(previouslyMarkedText)
                    return
                }
            }
            beginTextInputEdit()
            let rangeEndPosition = previouslyMarkedRange.endPosition
            _selectedTextRange = TextRange(from: rangeEndPosition, to: rangeEndPosition)
            _markedTextRange = nil
            endTextInputEdit()
            updateIMECompositionOverlay()
        }
    }
    
    public var beginningOfDocument: UITextPosition {
        return TextPosition(offset: 0)
    }
    
    public var endOfDocument: UITextPosition {
        return TextPosition(offset: textInputStorage.count)
    }
    
    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = coerceTextPosition(fromPosition),
              let to = coerceTextPosition(toPosition) else {
            uitiLog("textRange(from:\(type(of: fromPosition)), to:\(type(of: toPosition))) -> nil \(textInputStateDescription())")
            return nil
        }
        let range = TextRange(from: from, to: to)
        uitiLog("textRange(from:\(from.offset), to:\(to.offset)) -> \(range)")
        return range
    }
    
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let from = position as? TextPosition else { return nil }
        let newOffset = max(min(from.offset + offset, textInputStorage.count), 0)
        let result = TextPosition(offset: newOffset)
        uitiLog("position(from:\(from.offset), offset:\(offset)) -> \(result.offset)")
        return result
    }
    
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        return self.position(from: position, offset: offset)
    }
    
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let from = position as? TextPosition, let to = other as? TextPosition else { return .orderedDescending }
        if from.offset < to.offset {
            return .orderedAscending
        } else if from.offset > to.offset {
            return .orderedDescending
        } else {
            return .orderedSame
        }
    }
    
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TextPosition, let to = toPosition as? TextPosition else { return 0 }
        let result = to.offset - from.offset
        uitiLog("offset(from:\(from.offset), to:\(to.offset)) -> \(result)")
        return result
    }
            
    public func firstRect(for range: UITextRange) -> CGRect {
        return bounds
    }
    
    public func caretRect(for position: UITextPosition) -> CGRect {
        return bounds
    }
    
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? TextRange else { return [] }
        return [TextSelectionRect(rect: bounds, range: r, string: textInputStorage)]
    }
    
    // These can be exercised by the hold-spacebar
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        // return text position where the cursor is located based on the current selection
        let selection = _selectedTextRange
            return selection.startPosition
    }
    
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let r = range as? TextRange else { return nil }
        return r.startPosition
    }
    
    public func characterRange(at point: CGPoint) -> UITextRange? {
        return TextRange(from: TextPosition(offset: 0), to: TextPosition(offset: textInputStorage.count))
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        return range.end
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? TextPosition else { return nil }
        return TextRange(from: p, to: TextPosition(offset: textInputStorage.count))
    }
    
    public func position(within range: UITextRange, atCharacterOffset offset: Int) -> UITextPosition? {
        guard let r = range as? TextRange else { return nil }
        let endOffset = r.startPosition.offset + offset
        if endOffset > r.endPosition.offset {
            return nil
        }
        return TextPosition(offset: endOffset)
    }
    
    public func characterOffset(of position: UITextPosition, within range: UITextRange) -> Int {
        guard let r = range as? TextRange, let p = position as? TextPosition else { return 0 }
        return p.offset - r.startPosition.offset
    }
    
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        return .leftToRight
    }
    
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // do nothing
    }

    public func dictationRecordingDidEnd() {
        uitiLog("dictationRecordingDidEnd() textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")
    }
    
    public func dictationRecognitionFailed() {
        uitiLog("dictationRecognitionFailed() textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")
    }
    
    // MARK: - Dictation Placeholder Support
    
    public var insertDictationResultPlaceholder: Any {
        return "[DICTATION]"
    }
        
    public func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        uitiLog("removeDictationResultPlaceholder placeholder: \(placeholder), willInsertResult: \(willInsertResult)")
    }
    
    public func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        uitiLog("insertDictationResult() phrases: \(dictationResult)")
        uitiLog("textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")
        
        // Combine all phrases into a single string
        let combinedText = dictationResult.map { $0.text }.joined()

        if combinedText.count > 0 {
            insertText(combinedText)
        }
    }
    
    /*
        Software trackpad when user long press the spacebar.
    */
    public func beginFloatingCursor(at point: CGPoint)
    {
        lastFloatingCursorLocation = point
    }

    public func updateFloatingCursor(at point: CGPoint)
    {
        //uitiLog("updateFloatingCursor(at: \(point)) lastFloatingCursorLocation: \(lastFloatingCursorLocation)")
        guard let lastPosition = lastFloatingCursorLocation else {
            return
        }
        let deltax = lastPosition.x - point.x
        
        // Defines how sensitive the cursor is to "trackpad" movements. 
        // 5 is a happy medium between fast moving and precise enough.
        if abs(deltax) > 5 {
            var data: [UInt8]
            if deltax > 0 {
                data = terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
                // Update the carret to the new position so that deleteBackward will delete the correct character
                let newOffset = max(_selectedTextRange.startPosition.offset - 1, 0)
                selectedTextRange = TextRange(from: TextPosition(offset: newOffset), 
                    to: TextPosition(offset: newOffset))
            } else {
                data = terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
                // Update the carret to the new position so that deleteForward will delete the correct character
                let newOffset = min(_selectedTextRange.startPosition.offset + 1, textInputStorage.count)
                selectedTextRange = TextRange(from: TextPosition(offset: newOffset), 
                    to: TextPosition(offset: newOffset))
            }
            send (data)
            lastFloatingCursorLocation = point
        }

        if terminal.isCurrentBufferAlternate {
            let deltay = lastPosition.y - point.y

            var data: [UInt8]
            if abs (deltay) > 2 {
                if deltay > 0 {
                    data = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
                } else {
                    data = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
                }
                send (data)
                lastFloatingCursorLocation = point
            }
        }
    }
    
    public func endFloatingCursor()
    {
        lastFloatingCursorLocation = nil
    }
}

#endif
