import SwiftUI
import SwiftTerm
import UIKit
import MoshpitKit

/// Multiline draft editor. Return inserts a newline; the paper-plane button sends.
struct TerminalComposerView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onFocus: () -> Void
    let onKeyboardDismiss: () -> Void

    init(text: Binding<String>, isFocused: Binding<Bool>, onFocus: @escaping () -> Void,
         onKeyboardDismiss: @escaping () -> Void = {}) {
        self._text = text
        self._isFocused = isFocused
        self.onFocus = onFocus
        self.onKeyboardDismiss = onKeyboardDismiss
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
        view.returnKeyType = .default
        view.enablesReturnKeyAutomatically = false
        view.isScrollEnabled = true
        view.accessibilityIdentifier = "terminal-composer"
        view.accessibilityLabel = "待发送内容"
        view.accessibilityHint = String(localized: "Return inserts a new line. Use Send + Return to submit the draft.")
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
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

    /// External additions (voice and attachments) follow a caret at the end.
    /// An in-progress edit or selection elsewhere keeps its position.
    func updateDraftText(_ draft: String) {
        guard text != draft, markedTextRange == nil else { return }
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
