import SwiftUI

struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var color: Color = Theme.text2
    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
        .lineLimit(1)
    }
}

