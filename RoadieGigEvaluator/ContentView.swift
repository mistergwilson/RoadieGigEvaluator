import SwiftUI
import CoreLocation

struct ContentView: View {
    @State private var showPicker = false
    @State private var screenshot: UIImage?
    @State private var parsed: OCRService.Parsed?
    @State private var extraMilesToPickup: Double?
    @State private var result: GigComputation?
    @State private var vehicle = VehicleSettings()

    // Editable fields (prefilled after OCR, but always user-editable)
    @State private var payInput: String = ""
    @State private var milesInput: String = ""
    @State private var extraInput: String = ""

    @StateObject private var location = LocationService()
    private let ocr = OCRService()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // Screenshot card
                    GroupBox("Screenshot") {
                        VStack(spacing: 12) {
                            if let screenshot {
                                Image(uiImage: screenshot)
                                    .resizable()
                                    .scaledToFit()
                                    .cornerRadius(8)
                            } else {
                                Text("Import a Roadie screenshot")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Button { showPicker = true } label: { Text("Import Screenshot") }
                                if parsed != nil {
                                    Button { runOCR() } label: { Text("Re-run OCR") }
                                }
                            }
                        }
                    }

                    // Parsed values + editable overrides
                    GroupBox("Extracted / Edit Values") {
                        VStack(alignment: .leading, spacing: 10) {

                            EditableRow(title: "Pay ($)", text: $payInput, placeholder: "15.80", keyboard: .decimalPad)

                            EditableRow(title: "Gig miles (Roadie)", text: $milesInput, placeholder: "11", keyboard: .decimalPad)

                            EditableRow(title: "Distance to pickup (mi)", text: $extraInput, placeholder: "4.2", keyboard: .decimalPad)

                            HStack {
                                Button {
                                    Task { await estimatePickupDistance() }
                                } label: { Text("Auto-estimate distance to pickup") }
                                .disabled(parsed?.pickupQuery == nil)
                            }
                            .padding(.top, 4)

                            if let city = parsed?.pickupQuery {
                                Text("Pickup (guessed): \(city)")
                                    .font(.footnote).foregroundColor(.secondary)
                            } else {
                                Text("Pickup (guessed): —")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                        }
                    }

                    // Fuel & vehicle on main screen
                    GroupBox("Fuel & Vehicle") {
                        VStack(spacing: 10) {
                            HStack {
                                Text("MPG")
                                Spacer()
                                TextField("28", value: $vehicle.mpg, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 100)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Gas price ($/gal)")
                                Spacer()
                                TextField("4.80", value: $vehicle.gasPriceUSDPerGallon, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 100)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Text("Used to compute fuel cost and net $/mi for the verdict.")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }

                    // Evaluate button (enabled when all three numeric inputs present)
                    Button {
                        let pay = Double(payInput) ?? 0
                        let gm  = Double(milesInput) ?? 0
                        let ex  = Double(extraInput) ?? 0
                        result = GigEvaluator.evaluate(
                            pay: pay,
                            gigMiles: gm,
                            extraMilesToPickup: ex,
                            mpg: vehicle.mpg,
                            gasPrice: vehicle.gasPriceUSDPerGallon
                        )
                    } label: {
                        Text("Evaluate Gig")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Double(payInput) == nil || Double(milesInput) == nil || Double(extraInput) == nil)

                    // Result
                    if let r = result {
                        GroupBox("Verdict") {
                            VStack(alignment: .leading, spacing: 10) {
                                Stoplight(verdict: r.verdict)
                                Row("Total miles", value: String(format: "%.1f mi", r.totalMiles))
                                Row("Net $ per mile (after fuel)", value: String(format: "$%.2f", r.dollarsPerMile))
                                Row("Fuel cost (est.)", value: String(format: "$%.2f", r.fuelCost))
                                Row("Profit after fuel", value: String(format: "$%.2f", r.profitAfterFuel))
                                Text("Thresholds (after fuel): green ≥ $2/mi, yellow ≥ $1/mi, else red.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Roadie Gig Evaluator")
            .toolbar {
                NavigationLink(destination: SettingsView(settings: $vehicle)) {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            ImagePicker(selectedImage: $screenshot)
                .onDisappear { runOCR() }
        }
        .onAppear { location.request() }
    }

    private func runOCR() {
        guard let screenshot else { return }
        parsed = nil
        result = nil
        ocr.parse(image: screenshot) { parsed in
            DispatchQueue.main.async {
                self.parsed = parsed
                // Prefill editable fields from OCR (or keep previous if nil)
                if let p = parsed.payUSD { self.payInput = String(format: "%.2f", p) }
                if let m = parsed.gigMiles { self.milesInput = String(format: "%.1f", m) }
                if let e = self.extraMilesToPickup {
                    self.extraInput = String(format: "%.1f", e)
                } else if self.extraInput.isEmpty {
                    // leave blank; user can auto-estimate or type manually
                }
            }
        }
    }

    private func estimatePickupDistance() async {
        guard let pickup = parsed?.pickupQuery else { return }
        guard let userLoc = location.currentLocation else { return }
        if let coord = await location.resolveCoordinate(query: pickup) {
            let miles = location.distanceMiles(from: userLoc, to: coord)
            await MainActor.run {
                self.extraMilesToPickup = miles
                self.extraInput = String(format: "%.1f", miles) // update editable field
            }
        }
    }
}

// MARK: - Small UI helpers

private struct Row: View {
    var label: String
    var value: String
    init(_ label: String, value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}

private struct EditableRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    var keyboard: UIKeyboardType = .decimalPad
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct Stoplight: View {
    let verdict: Verdict
    var color: Color {
        switch verdict {
        case .good: return .green
        case .ok:   return .yellow
        case .bad:  return .red
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 18, height: 18)
            Text(verdict.rawValue.capitalized).font(.headline)
        }
    }
}
