import AppKit
import SwiftUI

struct MenuPopoverWindow: NSViewRepresentable {
    let needsMaterial: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSView) {
        configureMaterial(in: view)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
        }
    }

    private func configureMaterial(in view: NSView) {
        if let material = view.subviews.first as? NSVisualEffectView {
            material.isHidden = !needsMaterial
        } else if needsMaterial {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.frame = view.bounds
            material.autoresizingMask = [.width, .height]
            view.addSubview(material)
        }
    }
}
