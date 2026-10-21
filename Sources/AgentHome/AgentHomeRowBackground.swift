import SwiftUI

extension View {
    /// The rounded highlight behind a sidebar row: stronger when selected, faint on hover.
    func agentHomeRowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
        )
    }
}
