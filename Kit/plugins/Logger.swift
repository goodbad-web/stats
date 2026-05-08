//
//  Logger.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 24/06/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import os

public enum LogLevel: String {
    case debug = "DBG"
    case info  = "INF"
    case error = "ERR"
}

public enum LogOption: Int {
    case timestamp
    case level
    case file
    case line
    
    public static func new() -> [LogOption] {
        return [.timestamp, .file, .line, .level]
    }
}

public enum LogWriter: Int {
    case stdout
    case stderr
    case file
}

public class NextLog {
    public static let shared = NextLog()
    
    private let logger: Logger
    private let category: String
    
    public init(category: String = "default") {
        self.category = category
        self.logger = Logger(subsystem: "eu.exelban.Stats", category: category)
    }
    
    // For backward compatibility
    public convenience init(writer: LogWriter) {
        self.init(category: "default")
    }
    
    public func copy(category: String? = nil) -> NextLog {
        return NextLog(category: category ?? self.category)
    }
    
    public func log(level: LogLevel, options: [LogOption] = LogOption.new(), message: String, file: String = #file, line: UInt = #line) {
        let fileName = (file as NSString).lastPathComponent
        let formattedMessage = "[\(fileName):\(line)] \(message)"
        
        switch level {
        case .debug:
            self.logger.debug("\(formattedMessage, privacy: .public)")
        case .info:
            self.logger.info("\(formattedMessage, privacy: .public)")
        case .error:
            self.logger.error("\(formattedMessage, privacy: .public)")
        }
    }
}

public func debug(_ message: String, log: NextLog = NextLog.shared, file: String = #file, line: UInt = #line) {
    log.log(level: .debug, message: message, file: file, line: line)
}

public func info(_ message: String, log: NextLog = NextLog.shared, file: String = #file, line: UInt = #line) {
    log.log(level: .info, message: message, file: file, line: line)
}

public func error(_ message: String, log: NextLog = NextLog.shared, file: String = #file, line: UInt = #line) {
    log.log(level: .error, message: message, file: file, line: line)
}

public func error_msg(_ message: String, log: NextLog = NextLog.shared, file: String = #file, line: UInt = #line) {
    log.log(level: .error, message: message, file: file, line: line)
}
