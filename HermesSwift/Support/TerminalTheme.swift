import SwiftUI

/// HermesSwift black/green terminal visual identity.
/// True black base with a custom phosphor green instead of stock SwiftUI green.
enum TerminalTheme {
    static let background = Color.black
    static let text = Color(red: 0.25, green: 1.0, blue: 0.45)
    static let secondaryText = text.opacity(0.68)
    static let tertiaryText = text.opacity(0.42)
    static let card = text.opacity(0.075)
    static let userBubble = text.opacity(0.16)
    static let assistantBubble = Color.black
    static let border = text.opacity(0.34)
    static let faintBorder = text.opacity(0.18)
    static let fieldFill = text.opacity(0.055)
    static let glow = text.opacity(0.55)
}
