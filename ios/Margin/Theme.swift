import SwiftUI

extension Color {
    static let marginInk = Color(red: 0.08, green: 0.12, blue: 0.14)
    static let marginCream = Color(red: 0.96, green: 0.95, blue: 0.90)
    static let marginLime = Color(red: 0.75, green: 0.88, blue: 0.35)
    static let marginMint = Color(red: 0.45, green: 0.76, blue: 0.61)
    static let marginCoral = Color(red: 0.92, green: 0.42, blue: 0.33)
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.black.opacity(0.05)))
    }
}

extension View { func marginCard() -> some View { modifier(CardModifier()) } }

extension View {
    /// Number pads have no Return key, so a screen with amount fields gets a Done button above the keyboard, and
    /// scrolling dismisses it. Without this the keyboard can cover the screen's own buttons with no way to close it.
    func numberPadDone() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                // Any keyboard toolbar makes SwiftUI (iOS 27) log "Invalid frame dimension" once as the keyboard appears;
                // it's internal to the toolbar's layout and harmless (checked in the simulator).
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }.bold()
                }
            }
    }
}
