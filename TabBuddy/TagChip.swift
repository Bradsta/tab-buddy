import SwiftUI

struct TagChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        Text(label)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.25)
                                 : Color.secondary.opacity(0.18))
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .clipShape(Capsule())
            .onTapGesture(perform: action)
    }
}
