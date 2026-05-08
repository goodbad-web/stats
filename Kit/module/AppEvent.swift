//
//  AppEvent.swift
//  Kit
//
//  Created by Codex on 08/05/2026.
//

import Foundation

public enum AppEvent {
    case pause(Bool)
    case moduleToggle(module: String, state: Bool?)
    case popupToggle(module: String)
    case openWindow(module: String?, state: Bool)
}

public final class AppEventCenter: @unchecked Sendable {
    public static let shared = AppEventCenter()
    
    private let center: NotificationCenter
    
    public init(center: NotificationCenter = .default) {
        self.center = center
    }
    
    public func post(_ event: AppEvent) {
        switch event {
        case let .pause(state):
            self.center.post(name: .pause, object: nil, userInfo: ["state": state])
        case let .moduleToggle(module, state):
            var userInfo: [String: Any] = ["module": module]
            if let state {
                userInfo["state"] = state
            }
            self.center.post(name: .toggleModule, object: nil, userInfo: userInfo)
        case let .popupToggle(module):
            self.center.post(name: .togglePopup, object: nil, userInfo: ["module": module])
        case let .openWindow(module, state):
            var userInfo: [String: Any] = ["state": state]
            if let module {
                userInfo["module"] = module
            }
            self.center.post(name: .openWindow, object: nil, userInfo: userInfo)
        }
    }
    
    public func openWindow(from notification: Notification) -> (module: String?, state: Bool)? {
        guard let state = notification.userInfo?["state"] as? Bool else { return nil }
        return (notification.userInfo?["module"] as? String, state)
    }
    
    public func moduleToggle(from notification: Notification) -> (module: String, state: Bool?)? {
        guard let module = notification.userInfo?["module"] as? String else { return nil }
        return (module, notification.userInfo?["state"] as? Bool)
    }
}
