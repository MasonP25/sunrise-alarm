import SwiftUI
import UIKit

/// Wraps the native UIKit color picker (grid / spectrum / sliders tabs) as a SwiftUI sheet.
/// Skips SwiftUI's `ColorPicker` intermediate circle — presents the full picker immediately.
struct FullColorPickerSheet: UIViewControllerRepresentable {
    @Binding var color: Color
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let vc = UIColorPickerViewController()
        vc.selectedColor = UIColor(color)
        vc.supportsAlpha = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIColorPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color, onDone: onDone)
    }

    class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        @Binding var color: Color
        let onDone: () -> Void

        init(color: Binding<Color>, onDone: @escaping () -> Void) {
            _color = color
            self.onDone = onDone
        }

        func colorPickerViewControllerDidSelectColor(_ vc: UIColorPickerViewController) {
            color = Color(vc.selectedColor)
        }

        func colorPickerViewControllerDidFinish(_ vc: UIColorPickerViewController) {
            onDone()
        }
    }
}
