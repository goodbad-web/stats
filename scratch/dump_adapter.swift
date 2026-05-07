import Foundation
import IOKit.ps

if let details = IOPSCopyExternalPowerAdapterDetails() {
    let dict = details.takeRetainedValue() as? [String: Any]
    print(dict ?? "nil")
} else {
    print("No adapter details found")
}
