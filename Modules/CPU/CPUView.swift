import SwiftUI
import Charts
import Kit

public struct CPUView: View {
    var load: Kit.ObservableModel<CPU_Load>
    var frequency: Kit.ObservableModel<CPU_Frequency>
    var temperature: Kit.ObservableModel<Double>
    
    public init(load: Kit.ObservableModel<CPU_Load>, frequency: Kit.ObservableModel<CPU_Frequency>, temperature: Kit.ObservableModel<Double>) {
        self.load = load
        self.frequency = frequency
        self.temperature = temperature
    }
    
    public var body: some View {
        HStack(spacing: 15) {
            // Temperature Circle
            DashboardCircle(
                value: temperature.value ?? 0,
                max: 100,
                label: "Temp",
                unit: "°C",
                color: .orange
            )
            
            // Main Usage Circle
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.05), lineWidth: 8)
                
                if let data = load.value {
                    Circle()
                        .trim(from: 0, to: data.userLoad)
                        .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    
                    Circle()
                        .trim(from: data.userLoad, to: data.userLoad + data.systemLoad)
                        .stroke(Color.red.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    
                    VStack(spacing: -2) {
                        Text("\(Int(data.totalUsage * 100))")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 75, height: 75)
            
            // Frequency Circle
            DashboardCircle(
                value: frequency.value?.value ?? 0,
                max: 5000,
                label: "Freq",
                unit: "MHz",
                color: .green
            )
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

struct DashboardCircle: View {
    let value: Double
    let max: Double
    let label: String
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(value / max, 1.0))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: -1) {
                    Text("\(Int(value))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(unit)
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 45, height: 45)
            
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
