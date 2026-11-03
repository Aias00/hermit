import SwiftUI
import SwiftTerm
import UIKit
import MoshpitKit
import Observation

/// A one-shot modifier belongs to the coordinator on which it was armed.
/// Cancelling after a pane switch must clear the old owner, not the new pane.
@MainActor @Observable
final class TerminalControlModifier {
    private(set) var isArmed = false
    @ObservationIgnored private weak var owner: SwiftTerminalView.Coordinator?

    func arm(on coordinator: SwiftTerminalView.Coordinator) {
        cancel()
        owner = coordinator
        isArmed = true
        coordinator.pendingCtrl = true
        coordinator.onPendingCtrlConsumed = { [weak self, weak coordinator] in
            guard let self, let coordinator, self.owner === coordinator else { return }
            self.cancel()
        }
    }

    func applies(to coordinator: SwiftTerminalView.Coordinator?) -> Bool {
        guard isArmed else { return false }
        guard let coordinator, owner === coordinator else {
            cancel()
            return false
        }
        return true
    }

    func cancel() {
        guard isArmed else { return }
        owner?.pendingCtrl = false
        owner?.onPendingCtrlConsumed = nil
        owner = nil
        isArmed = false
    }
}

/// Weak editor handle for explicit newline and remote editing actions.
@MainActor
final class TerminalComposerEditor {
    weak var view: ComposerTextView?
    func insertNewline() { view?.insertDraftLineBreak() }
    func resumeRemoteEditing() { view?.resumeRemoteEditing() }
}

/// Multiline editor. With a submit handler, Return sends; Shift+Return adds a line.
struct TerminalComposerView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onFocus: () -> Void
    let onKeyboardDismiss: () -> Void
    let onSubmit: (() -> Void)?
    let editor: TerminalComposerEditor?
    var onEmptyDelete: (() -> Void)?
    var onEmptyArrow: ((String) -> Void)?
    var onControlKey: ((UInt8) -> Void)?
    var consumeControlText: ((String) -> Bool)?
    var onLiteralInput: (() -> Void)?

    init(text: Binding<String>, isFocused: Binding<Bool>, onFocus: @escaping () -> Void,
         onKeyboardDismiss: @escaping () -> Void = {},
         onSubmit: (() -> Void)? = nil, editor: TerminalComposerEditor? = nil,
         onEmptyDelete: (() -> Void)? = nil, onEmptyArrow: ((String) -> Void)? = nil,
         onControlKey: ((UInt8) -> Void)? = nil, consumeControlText: ((String) -> Bool)? = nil,
         onLiteralInput: (() -> Void)? = nil) {
        self._text = text
        self._isFocused = isFocused
        self.onFocus = onFocus
        self.onKeyboardDismiss = onKeyboardDismiss
        self.onSubmit = onSubmit
        self.editor = editor
        self.onEmptyDelete = onEmptyDelete
        self.onEmptyArrow = onEmptyArrow
        self.onControlKey = onControlKey
        self.consumeControlText = consumeControlText
        self.onLiteralInput = onLiteralInput
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 16)
        view.textColor = UIColor(red: 0.72, green: 0.80, blue: 0.88, alpha: 1)
        view.backgroundColor = .clear
        view.overrideUserInterfaceStyle = .dark
        view.textContainerInset = UIEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.returnKeyType = onSubmit == nil ? .default : .send
        view.enablesReturnKeyAutomatically = false
        view.isScrollEnabled = true
        view.accessibilityIdentifier = "terminal-composer"
        view.accessibilityLabel = "待发送内容"
        context.coordinator.configureReturn(view)
        editor?.view = view
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.configureReturn(view)
        editor?.view = view
        view.updateDraftText(text)
        view.updatePlaceholder()
        coordinator.updateFocus(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maximum = (uiView.font?.lineHeight ?? 20) * 4 + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        return CGSize(width: width, height: min(maximum, max(34, ceil(measured.height))))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TerminalComposerView
        private var focusGeneration = 0
        private var preservesFocusForPendingEnd = false
        private var resolvingEndEditing = false
        init(_ parent: TerminalComposerView) { self.parent = parent }

        func configureReturn(_ view: ComposerTextView) {
            let keyType: UIReturnKeyType = parent.onSubmit == nil ? .default : .send
            if view.returnKeyType != keyType { view.returnKeyType = keyType }
            view.accessibilityHint = parent.onSubmit == nil
                ? String(localized: "Return inserts a new line. Use Send + Return to submit the draft.")
                : String(localized: "Return sends the draft. Shift+Return or New line inserts a line break.")
            view.onReturn = parent.onSubmit == nil ? nil : { [weak self] in
                // didChange publishes edits as they happen. The binding may
                // already have been cleared by an acknowledged send before
                // UIKit paints it; never resurrect the old editor value here.
                self?.parent.onSubmit?()
            }
            view.onEmptyDelete = parent.onEmptyDelete == nil ? nil : { [weak self] in self?.parent.onEmptyDelete?() }
            view.onEmptyArrow = parent.onEmptyArrow == nil ? nil : { [weak self] in self?.parent.onEmptyArrow?($0) }
            view.onControlKey = parent.onControlKey == nil ? nil : { [weak self] in self?.parent.onControlKey?($0) }
            view.consumeControlText = { [weak self] in self?.parent.consumeControlText?($0) ?? false }
            view.onLiteralInput = { [weak self] in self?.parent.onLiteralInput?() }
        }

        func updateFocus(_ view: ComposerTextView) {
            focusGeneration += 1
            let generation = focusGeneration
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.applyFocus(view, generation: generation)
            }
        }

        private func applyFocus(_ view: ComposerTextView, generation: Int) {
            guard focusGeneration == generation else { return }
            if parent.isFocused {
                guard view.window != nil else { return }
                if resolvingEndEditing || UIApplication.shared.applicationState != .active
                    || Self.hasPresentedController(in: view.window) {
                    // The binding can be restored while UIKit is still
                    // dismissing its controller. Wait for the real dismissal,
                    // even when no later terminal repaint is forthcoming.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.applyFocus(view, generation: generation)
                    }
                    return
                }
                if !view.isFirstResponder { view.becomeFirstResponder() }
            } else if view.isFirstResponder { view.resignFirstResponder() }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            resolvingEndEditing = false
            // Revoke terminal focus immediately, before a queued terminal take
            // can run on the next SwiftUI layout pass.
            parent.onFocus()
            if !parent.isFocused { parent.isFocused = true }
        }
        func textViewShouldEndEditing(_ textView: UITextView) -> Bool {
            // Capture this before UIKit yields the responder. A sheet has
            // already suspended the binding here; its later dismissal may
            // restore it before didEnd's deferred work runs.
            preservesFocusForPendingEnd = !parent.isFocused
                || UIApplication.shared.applicationState != .active
                || Self.hasPresentedController(in: textView.window)
            Log.input.info("composer shouldEnd: focused=\(self.parent.isFocused, privacy: .public) temporary=\(self.preservesFocusForPendingEnd, privacy: .public)")
            return true
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            let preserveFocus = preservesFocusForPendingEnd
            preservesFocusForPendingEnd = false
            Log.input.info("composer didEnd: temporary=\(preserveFocus, privacy: .public)")
            guard !preserveFocus else {
                if let view = textView as? ComposerTextView { updateFocus(view) }
                return
            }
            // The system keyboard's own Hide key doesn't change our binding.
            // Fence queued focus requests now, then let UIKit finish assigning
            // the next responder before distinguishing Hide from a terminal tap.
            focusGeneration += 1
            resolvingEndEditing = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.resolvingEndEditing = false
                guard let textView, !textView.isFirstResponder, self.parent.isFocused,
                      UIApplication.shared.applicationState == .active,
                      let window = textView.window else { return }
                // SwiftUI Menu can ask the editor to resign before it has
                // installed its popover controller. Recheck after UIKit's
                // presentation work, otherwise its temporary borrow is
                // mistaken for Hide and the binding update closes the menu.
                let presented = Self.hasPresentedController(in: window)
                Log.input.info("composer resolvedEnd: presented=\(presented, privacy: .public)")
                guard !presented else {
                    if let view = textView as? ComposerTextView { self.updateFocus(view) }
                    return
                }
                let terminalTookFocus = Self.hasFocusedTerminal(in: window)
                self.parent.isFocused = false
                if !terminalTookFocus { self.parent.onKeyboardDismiss() }
            }
        }

        private static func hasFocusedTerminal(in view: UIView) -> Bool {
            if view is TerminalView, view.isFirstResponder { return true }
            return view.subviews.contains { hasFocusedTerminal(in: $0) }
        }

        private static func hasPresentedController(in window: UIWindow?) -> Bool {
            guard let root = window?.rootViewController else { return false }
            func hasPresentation(_ controller: UIViewController) -> Bool {
                if controller.presentedViewController != nil { return true }
                return controller.children.contains { hasPresentation($0) }
            }
            return hasPresentation(root)
        }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? ComposerTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
        }

    }
}

final class ComposerTextView: UITextView {
    private let placeholder = UILabel()
    var onReturn: (() -> Void)?
    var onEmptyDelete: (() -> Void)?
    var onEmptyArrow: ((String) -> Void)?
    var onControlKey: ((UInt8) -> Void)?
    var consumeControlText: ((String) -> Bool)?
    var onLiteralInput: (() -> Void)?
    private var insertingDictation = false
    private var deletedLocalText = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        placeholder.text = "待发送内容"
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .secondaryLabel
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var keyCommands: [UIKeyCommand]? {
        var commands = (super.keyCommands ?? []).filter { !($0.input == "\r" && $0.modifierFlags == .shift) }
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(shiftReturn(_:)))
        newline.discoverabilityTitle = String(localized: "New line")
        newline.wantsPriorityOverSystemBehavior = true
        commands.append(newline)
        if markedTextRange == nil {
            // Only an empty draft lends navigation to the remote. With text
            // present, UIKit keeps normal caret movement and selection.
            if text.isEmpty, onEmptyArrow != nil {
                for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                              UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
                    let arrow = UIKeyCommand(input: input, modifierFlags: [], action: #selector(emptyArrow(_:)))
                    arrow.wantsPriorityOverSystemBehavior = true
                    commands.append(arrow)
                }
            }
            if onControlKey != nil {
                let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                          action: #selector(remoteEscape(_:)))
                escape.wantsPriorityOverSystemBehavior = true
                commands.append(escape)
                for byte in UInt8(ascii: "a")...UInt8(ascii: "z") {
                    let control = UIKeyCommand(input: String(UnicodeScalar(byte)), modifierFlags: .control,
                                               action: #selector(controlKey(_:)))
                    control.wantsPriorityOverSystemBehavior = true
                    commands.append(control)
                }
            }
        }
        return commands
    }

    @objc private func emptyArrow(_ command: UIKeyCommand) {
        guard text.isEmpty, markedTextRange == nil, let input = command.input else { return }
        let directions = [UIKeyCommand.inputUpArrow: "up", UIKeyCommand.inputDownArrow: "down",
                          UIKeyCommand.inputLeftArrow: "left", UIKeyCommand.inputRightArrow: "right"]
        if let direction = directions[input] {
            deletedLocalText = false
            onEmptyArrow?(direction)
        }
    }

    @objc private func controlKey(_ command: UIKeyCommand) {
        guard markedTextRange == nil, let byte = command.input?.utf8.first else { return }
        onControlKey?(byte & 0x1f)
    }

    @objc private func remoteEscape(_ command: UIKeyCommand) {
        guard markedTextRange == nil else { return }
        onControlKey?(0x1b)
    }

    override func deleteBackward() {
        if text.isEmpty, markedTextRange == nil, !insertingDictation, let onEmptyDelete {
            // Holding Delete to clear a local draft must stop at the boundary;
            // it must not continue deleting an unrelated remote command.
            if !deletedLocalText { onEmptyDelete() }
        } else {
            deletedLocalText = true
            super.deleteBackward()
        }
    }

    override var hasText: Bool {
        super.hasText || (onEmptyDelete != nil && !deletedLocalText)
    }

    func resumeRemoteEditing() {
        guard text.isEmpty, markedTextRange == nil else { return }
        deletedLocalText = false
    }

    override func becomeFirstResponder() -> Bool {
        if !isFirstResponder { deletedLocalText = false }
        return super.becomeFirstResponder()
    }

    @objc private func shiftReturn(_ command: UIKeyCommand) { insertDraftLineBreak() }

    func insertDraftLineBreak() {
        onLiteralInput?()
        if markedTextRange != nil { unmarkText() }
        super.insertText("\n")
    }

    override func insertText(_ text: String) {
        if !insertingDictation, consumeControlText?(text) == true {
            // insertText is an IME commit; intermediate candidates arrive via
            // setMarkedText. A committed Ctrl letter must not remain in the
            // local draft, even when it replaces marked Pinyin text.
            if let marked = markedTextRange {
                super.replace(marked, withText: "")
                unmarkText()
            }
            return
        }
        if (text == "\n" || text == "\r" || text == "\r\n"), let onReturn, !insertingDictation {
            if markedTextRange != nil {
                // The first Return confirms composition; it must never send a
                // half-composed Chinese word or accept a remote prompt.
                unmarkText()
            } else {
                deletedLocalText = false
                onReturn()
            }
            return
        }
        super.insertText(text)
    }

    override func paste(_ sender: Any?) {
        onLiteralInput?()
        // A deliberate paste is text even when the clipboard is exactly one
        // newline. Bypass the keyboard Return shortcut and keep all paragraphs.
        if let text = UIPasteboard.general.string { super.insertText(text) }
        else { super.paste(sender) }
    }

    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        insertDictatedText(dictationResult.map(\.text).joined())
    }

    /// UITextView does not implement the optional insertDictationResult
    /// superclass method on every OS. Insert its most likely phrases as text.
    func insertDictatedText(_ text: String) {
        onLiteralInput?()
        guard !text.isEmpty else { return }
        insertingDictation = true
        defer { insertingDictation = false }
        super.insertText(text)
    }

    /// External additions (voice and attachments) follow a caret at the end.
    /// An in-progress edit or selection elsewhere keeps its position.
    func updateDraftText(_ draft: String) {
        guard text != draft, markedTextRange == nil else { return }
        deletedLocalText = false
        let selection = selectedRange
        let wasAtEnd = selection.length == 0 && selection.location == (text as NSString).length
        text = draft
        let length = (draft as NSString).length
        let start = wasAtEnd ? length : min(selection.location, length)
        selectedRange = NSRange(location: start, length: min(selection.length, length - start))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
            width: max(0, bounds.width - textContainerInset.left - textContainerInset.right),
            height: font?.lineHeight ?? 20)
        updatePlaceholder()
    }
    func updatePlaceholder() { placeholder.isHidden = !text.isEmpty }

}
