//
//  TextInput.swift
//  J2MEEmulator
//
//  Text entry helpers: MIDP TextField/TextBox constraints → iOS keyboard,
//  length limits, and an invisible key-input view that turns the iOS
//  keyboard into J2ME key presses for games that read text via keyPressed.
//

import UIKit

/// MIDP TextField / TextBox constraint flags
enum J2MEConstraints {
    static let emailAddr = 1
    static let numeric = 2
    static let phoneNumber = 3
    static let url = 4
    static let decimal = 5
    static let mask = 0xFFFF
    static let password = 0x10000
}

extension UITextField {
    /// Keyboard type and secure entry matching MIDP constraints.
    /// No autocorrection / smart punctuation: accounts and passwords must be typed verbatim.
    func applyJ2MEConstraints(_ constraints: Int) {
        switch constraints & J2MEConstraints.mask {
        case J2MEConstraints.numeric:     keyboardType = .asciiCapableNumberPad
        case J2MEConstraints.decimal:     keyboardType = .decimalPad
        case J2MEConstraints.phoneNumber: keyboardType = .phonePad
        case J2MEConstraints.emailAddr:   keyboardType = .emailAddress
        case J2MEConstraints.url:         keyboardType = .URL
        default:                          keyboardType = .default
        }
        isSecureTextEntry = (constraints & J2MEConstraints.password) != 0
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        clearButtonMode = .whileEditing
    }
}

/// Limits a text field to `maxLength` UTF-16 units (Java String length) and
/// runs `onReturn` when the Return key is pressed.
final class J2METextFieldDelegate: NSObject, UITextFieldDelegate {
    var maxLength: Int
    var onReturn: (() -> Void)?

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        guard maxLength > 0 else { return true }
        let current = (textField.text ?? "") as NSString
        return current.replacingCharacters(in: range, with: string).utf16.count <= maxLength
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return false
    }
}

/// Invisible view that shows the system keyboard and turns typed characters
/// into J2ME key codes (character code, -8 = delete, Return = fire).
final class KeyInputView: UIView, UIKeyInput {
    var onCharacter: ((Int32) -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }   // keep delivering Delete even when "empty"

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                onReturn?()
            } else {
                onCharacter?(Int32(bitPattern: scalar.value))
            }
        }
    }

    func deleteBackward() {
        onDelete?()
    }

    // UITextInputTraits
    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var returnKeyType: UIReturnKeyType = .done
}
