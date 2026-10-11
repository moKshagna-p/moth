import AppKit
import SwiftUI

// A dedicated editor keeps URL/query input literal without changing other fields.
final class PaletteInputCell: NSTextFieldCell {
    private let editor = NSTextView()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.isFieldEditor = true
        return editor
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        if let editor = text as? NSTextView {
            editor.isAutomaticTextCompletionEnabled = false
            editor.inlinePredictionType = .no
            editor.mathExpressionCompletionType = .no
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.enabledTextCheckingTypes = 0
            editor.writingToolsBehavior = .none
        }
        return text
    }
}

struct PaletteInput: NSViewRepresentable {
    @ObservedObject var model: ChromeModel
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = PaletteInputCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = .labelColor
        field.isAutomaticTextCompletionEnabled = false
        field.allowsWritingTools = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search or enter URL")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.placeholderString = placeholder
        if field.stringValue != model.paletteQuery { field.stringValue = model.paletteQuery }
        guard model.paletteMode != nil, context.coordinator.focus != model.paletteFocus else { return }
        context.coordinator.focus = model.paletteFocus
        DispatchQueue.main.async { [weak field, weak model] in
            guard let field, model?.paletteMode != nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: ChromeModel
        var focus: Int?
        init(model: ChromeModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.setPaletteInput(field.stringValue, composing: (field.currentEditor() as? NSTextView)?.hasMarkedText() == true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Let input methods commit their marked text before acting on the palette.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): model.submitPalette()
            case #selector(NSResponder.cancelOperation(_:)): model.closePalette()
            case #selector(NSResponder.moveUp(_:)): model.movePalette(-1)
            case #selector(NSResponder.moveDown(_:)): model.movePalette(1)
            case #selector(NSResponder.insertTab(_:)): return model.completePalette()
            case #selector(NSResponder.complete(_:)): break
            default: return false
            }
            return true
        }
    }
}
