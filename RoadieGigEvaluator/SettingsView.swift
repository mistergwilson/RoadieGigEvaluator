import SwiftUI

struct SettingsView: View {
    @Binding var settings: VehicleSettings

    var body: some View {
        Form {
            Section(header: Text("Vehicle")) {
                Stepper(value: $settings.mpg, in: 5...80, step: 0.5) {
                    HStack {
                        Text("MPG")
                        Spacer()
                        Text("\(settings.mpg, specifier: "%.1f")")
                    }
                }
            }
            Section(header: Text("Fuel")) {
                HStack {
                    Text("Gas price ($/gal)")
                    Spacer()
                    TextField("4.80", value: $settings.gasPriceUSDPerGallon, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
