import Foundation
import CoreLocation

struct GigInput: Identifiable {
    let id = UUID()
    var payUSD: Double?
    var gigMiles: Double?
    var pickupQuery: String? // e.g., "Oakland, CA"
}

struct VehicleSettings: Codable {
    var mpg: Double = 28
    var gasPriceUSDPerGallon: Double = 4.80
}

enum Verdict: String { case good, ok, bad }

struct GigComputation {
    var totalMiles: Double
    /// Net dollars per mile AFTER fuel cost
    var dollarsPerMile: Double
    var fuelCost: Double
    var profitAfterFuel: Double
    var verdict: Verdict
}

enum GigEvaluator {
    static func evaluate(pay: Double,
                         gigMiles: Double,
                         extraMilesToPickup: Double,
                         mpg: Double,
                         gasPrice: Double) -> GigComputation {

        let total = max(0, gigMiles + extraMilesToPickup)

        // Fuel & profit
        let gallons = (total > 0 && mpg > 0) ? total / mpg : 0
        let fuelCost = gallons * gasPrice
        let profit = pay - fuelCost

        // 👉 Apply thresholds to NET $/mi
        let netDollarsPerMile = total > 0 ? profit / total : 0

        let verdict: Verdict
        if netDollarsPerMile >= 2.0 { verdict = .good }
        else if netDollarsPerMile >= 1.0 { verdict = .ok }
        else { verdict = .bad }

        return .init(totalMiles: total,
                     dollarsPerMile: netDollarsPerMile,
                     fuelCost: fuelCost,
                     profitAfterFuel: profit,
                     verdict: verdict)
    }
}
