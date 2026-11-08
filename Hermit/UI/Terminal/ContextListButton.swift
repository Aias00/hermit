import SwiftUI
import UIKit

/// A list keeps its normal button/accessibility action, but touch taps are
/// exclusive: double tap opens a row menu without first selecting the row.
struct ContextListButton<Label: View>: View {
    let menu: ((UIView, CGPoint) -> Bool)?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var anchor: UIView?

    var body: some View {
        if let menu {
            Button(action: action, label: label)
                .background { ContextListAnchor { anchor = $0 } }
                .highPriorityGesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first(let tap): if let anchor { _ = menu(anchor, tap.location) }
                        case .second: action()
                        }
                    })
                .accessibilityAction(named: Text("操作菜单")) {
                    if let anchor { _ = menu(anchor, CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)) }
                }
        } else { Button(action: action, label: label) }
    }
}

private struct ContextListAnchor: UIViewRepresentable {
    let ready: (UIView) -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        DispatchQueue.main.async { ready(view) }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { }
}
