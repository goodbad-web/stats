import Observation
import Foundation

@Observable
public class ObservableModel<T> {
    public var value: T?
    public init(_ value: T? = nil) {
        self.value = value
    }
}
