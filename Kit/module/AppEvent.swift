//
//  AppEvent.swift
//  Kit
//
//  Created by Codex on 08/05/2026.
//

import Cocoa

public enum AppEvent {
    case pause(Bool)
    case moduleToggle(module: String, state: Bool?)
    case popupToggle(module: String, origin: CGPoint? = nil, center: CGFloat? = nil, widget: widget_t? = nil)
    case toggleWidget(module: String)
    case togglePreview(module: String)
    case toggleOneView(module: String?)
    case moduleRearrange(id: String?)
    case widgetRearrange(module: String)
    case combinedModulesPopup
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
        case let .popupToggle(module, origin, center, widget):
            var userInfo: [String: Any] = ["module": module]
            if let origin {
                userInfo["origin"] = origin
            }
            if let center {
                userInfo["center"] = center
            }
            if let widget {
                userInfo["widget"] = widget
            }
            self.center.post(name: .togglePopup, object: nil, userInfo: userInfo)
        case let .toggleWidget(module):
            self.center.post(name: .toggleWidget, object: nil, userInfo: ["module": module])
        case let .togglePreview(module):
            self.center.post(name: .togglePreview, object: nil, userInfo: ["module": module])
        case let .toggleOneView(module):
            var userInfo: [String: Any]?
            if let module {
                userInfo = ["module": module]
            }
            self.center.post(name: .toggleOneView, object: nil, userInfo: userInfo)
        case let .moduleRearrange(id):
            var userInfo: [String: Any]?
            if let id {
                userInfo = ["id": id]
            }
            self.center.post(name: .moduleRearrange, object: nil, userInfo: userInfo)
        case let .widgetRearrange(module):
            self.center.post(name: .widgetRearrange, object: nil, userInfo: ["module": module])
        case .combinedModulesPopup:
            self.center.post(name: .combinedModulesPopup, object: nil, userInfo: nil)
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

    public func popupToggle(from notification: Notification) -> (module: String, origin: CGPoint?, center: CGFloat?, widget: widget_t?)? {
        guard let module = notification.userInfo?["module"] as? String else { return nil }
        return (
            module,
            notification.userInfo?["origin"] as? CGPoint,
            notification.userInfo?["center"] as? CGFloat,
            notification.userInfo?["widget"] as? widget_t
        )
    }

    private func moduleName(from notification: Notification) -> String? {
        notification.userInfo?["module"] as? String
    }

    public func moduleRearrangeID(from notification: Notification) -> String? {
        notification.userInfo?["id"] as? String
    }

    public func toggleWidget(from notification: Notification) -> String? {
        self.moduleName(from: notification)
    }

    public func togglePreview(from notification: Notification) -> String? {
        self.moduleName(from: notification)
    }

    public func toggleOneView(from notification: Notification) -> String? {
        self.moduleName(from: notification)
    }

    public func widgetRearrange(from notification: Notification) -> String? {
        self.moduleName(from: notification)
    }

    public func openModuleSettings(from notification: Notification) -> String? {
        self.moduleName(from: notification)
    }

    public func toggleSettings(from notification: Notification) -> String? {
        self.moduleName(from: notification)
    }

    public func fanHelperState(from notification: Notification) -> Bool? {
        notification.userInfo?["state"] as? Bool
    }

    public func remoteAuthState(from notification: Notification) -> Bool? {
        notification.userInfo?["auth"] as? Bool
    }
}
