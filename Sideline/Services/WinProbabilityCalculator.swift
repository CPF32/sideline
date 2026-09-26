import Foundation

/// Computes a live win-probability estimate for a head-to-head fantasy matchup when the host
/// league API doesn't supply one directly (none of MFL, Sleeper, or ESPN do today).
///
/// Each side's remaining scoring is modeled as a normal distribution: players whose games are
/// final contribute their actual points with zero variance; players mid-game blend their
/// current pace toward their projection as the clock runs out, with shrinking variance; players
/// who haven't started carry their full projection and full projection-based variance. The two
/// sides' combined distributions are converted to a win probability via the standard normal CDF.
enum WinProbabilityCalculator {
    /// NFL game length used to turn `gameSecondsRemaining` into a completion fraction.
    private static let regulationSeconds: Double = 3600
    /// Typical fantasy-week standard deviation as a fraction of a player's projection.
    private static let projectionVolatility: Double = 0.42
    /// Below this combined variance, treat the outcome as already decided rather than dividing
    /// by a near-zero spread.
    private static let varianceFloor: Double = 0.0001

    private struct SideEstimate {
        var expectedTotal: Double
        var variance: Double
    }

    struct Result {
        /// Probability (0...1) that "mine" finishes with the higher score.
        var myProbability: Double
        /// Modeled final score for each side — final points already banked plus the
        /// expected value of everything still left to play. The same inputs that drive
        /// `myProbability`, shown alongside it so the odds are legible, not just asserted.
        var myProjectedFinal: Double
        var oppProjectedFinal: Double
    }

    /// Returns the win probability and each side's modeled final score, or `nil` when there
    /// isn't a lineup on either side to estimate from.
    static func evaluate(mine: [RosterPlayer], opponent: [RosterPlayer]) -> Result? {
        guard !mine.isEmpty, !opponent.isEmpty else { return nil }

        let myEstimate = estimate(for: mine)
        let oppEstimate = estimate(for: opponent)
        let diff = myEstimate.expectedTotal - oppEstimate.expectedTotal
        let combinedVariance = myEstimate.variance + oppEstimate.variance

        let probability: Double
        if combinedVariance > varianceFloor {
            let z = diff / combinedVariance.squareRoot()
            // Keep a sliver of doubt on either end — DNPs/injuries happen even at a "sure thing".
            probability = min(0.99, max(0.01, 0.5 * (1 + erf(z / 2.0.squareRoot()))))
        } else if diff > 0.05 {
            probability = 0.99
        } else if diff < -0.05 {
            probability = 0.01
        } else {
            probability = 0.5
        }

        return Result(
            myProbability: probability,
            myProjectedFinal: myEstimate.expectedTotal,
            oppProjectedFinal: oppEstimate.expectedTotal
        )
    }

    private static func estimate(for players: [RosterPlayer]) -> SideEstimate {
        var expectedTotal = 0.0
        var variance = 0.0

        for player in players {
            let lock = player.gameLockState ?? "upcoming"
            let projected = player.projectedPoints ?? 0
            let actual = player.actualPoints ?? 0

            switch lock {
            case "final":
                expectedTotal += actual

            case "started":
                let remainingSeconds = Double(player.gameSecondsRemaining ?? 0)
                let remainingFraction = min(1, max(0, remainingSeconds / regulationSeconds))
                let upside = max(0, projected - actual)
                expectedTotal += actual + upside * remainingFraction
                let sigma = projected * projectionVolatility * remainingFraction
                variance += sigma * sigma

            case "bye":
                continue

            default: // upcoming | unknown
                expectedTotal += projected
                let sigma = projected * projectionVolatility
                variance += sigma * sigma
            }
        }

        return SideEstimate(expectedTotal: expectedTotal, variance: variance)
    }
}
