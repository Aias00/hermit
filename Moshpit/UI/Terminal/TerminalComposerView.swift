import SwiftUI
import UIKit

/// Multiline draft editor. Return inserts a newline; the paper-plane button sends.
struct TerminalComposerView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onFocus: () -> Void

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
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            let start = min(selection.location, length)
            view.selectedRange = NSRange(location: start, length: min(selection.length, length - start))
        }
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
        init(_ parent: TerminalComposerView) { self.parent = parent }

        func updateFocus(_ view: ComposerTextView) {
            focusGeneration += 1
            let generation = focusGeneration
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.focusGeneration == generation else { return }
                if self.parent.isFocused {
                    if !view.isFirstResponder, view.window != nil { view.becomeFirstResponder() }
                } else if view.isFirstResponder { view.resignFirstResponder() }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // Revoke terminal focus immediately, before a queued terminal take
            // can run on the next SwiftUI layout pass.
            parent.onFocus()
            if !parent.isFocused { parent.isFocused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
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
        placeholder.text = "待发送内容 · 长按查看历史"
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .secondaryLabel
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
            width: max(0, bounds.width - textContainerInset.left - textContainerInset.right),
            height: font?.lineHeight ?? 20)
        updatePlaceholder()
    }
    func updatePlaceholder() { placeholder.isHidden = !text.isEmpty }

}
