import SwiftUI

/// Sleeper-style sliding win-probability bar: two segments that always sum to 100%
/// (green = mine, electric orange = opponent), with each side's percentage above its end.
struct WinProbabilityGaugeView: View {
    /// Probability (0...1) that "mine" wins.
    var myProbability: Double
    var barHeight: CGFloat = 4

    private var clamped: Double { min(1, max(0, myProbability)) }
    private var myPercent: Int { Int((clamped * 100).rounded()) }
    private var oppPercent: Int { 100 - myPercent }

    var body: some View {
        VStack(spacing: BrandTheme.space(3)) {
            HStack {
                HStack(spacing: 3) {
                    Text("\(myPercent)%")
                        .font(BrandTheme.mono(11, weight: .semibold))
                    Text("WIN")
                        .font(BrandTheme.body(8, weight: .semibold))
                        .tracking(0.5)
                }
                .foregroundStyle(BrandTheme.gaugeMine)

                Spacer()

                HStack(spacing: 3) {
                    Text("WIN")
                        .font(BrandTheme.body(8, weight: .semibold))
                        .tracking(0.5)
                    Text("\(oppPercent)%")
                        .font(BrandTheme.mono(11, weight: .semibold))
                }
                .foregroundStyle(BrandTheme.electricOrange)
            }

            GeometryReader { geo in
                let myWidth = geo.size.width * CGFloat(clamped)
                HStack(spacing: 0) {
                    Rectangle().fill(BrandTheme.gaugeMine)
                        .frame(width: myWidth)
                    Rectangle().fill(BrandTheme.electricOrange)
                        .frame(width: geo.size.width - myWidth)
                }
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.4), value: clamped)
            }
            .frame(height: barHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Win probability")
        .accessibilityValue("\(myPercent) percent versus \(oppPercent) percent")
    }
}

#Preview {
    VStack(spacing: 24) {
        WinProbabilityGaugeView(myProbability: 0.45)
        WinProbabilityGaugeView(myProbability: 0.82)
        WinProbabilityGaugeView(myProbability: 0.5)
    }
    .padding()
}
