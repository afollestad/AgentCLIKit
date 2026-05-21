import Foundation
import SwiftUI

struct WorkingIndicatorView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = dotProgress(at: timeline.date, index: index)
                    Circle()
                        .fill(Color.secondary.opacity(0.28 + (progress * 0.57)))
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.72 + (progress * 0.28))
                }
            }
        }
        .frame(height: 21, alignment: .center)
        .accessibilityLabel("Assistant is thinking")
    }

    private func dotProgress(at date: Date, index: Int) -> Double {
        let cycleDuration = 1.1
        let delay = Double(index) * 0.22
        let position = (date.timeIntervalSinceReferenceDate - delay).truncatingRemainder(dividingBy: cycleDuration)
        let normalized = position < 0 ? position + cycleDuration : position
        return (sin((normalized / cycleDuration) * .pi * 2 - (.pi / 2)) + 1) / 2
    }
}
