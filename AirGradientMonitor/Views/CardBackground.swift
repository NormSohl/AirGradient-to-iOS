import SwiftUI
import UIKit

extension View {
    /// The one card treatment used by every panel in the app.
    ///
    /// `secondarySystemBackground` rather than a hand-picked grey: it is the
    /// colour iOS itself uses for cards, so it tracks light/dark and increased
    /// contrast without this app maintaining a second palette.
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
