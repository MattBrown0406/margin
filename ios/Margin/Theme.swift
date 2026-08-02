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
