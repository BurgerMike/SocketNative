//
//  Struct.swift
//  SocketNativo
//
//  Created by Miguel Carlos Elizondo Martinez on 04/09/25.
//

import Foundation

public struct PlainMap {
    public var eventKey: String
    public var dataKey: String
    public init(eventKey: String = "event", dataKey: String = "data") {
        self.eventKey = eventKey
        self.dataKey = dataKey
    }
}

public struct ChatConfig {
    public var baseURL: URL              // https://siteqa.appstorage.net
    public var path: String              // "/QA/chat/socket" (SI) o "/ws" (WS puro)
    public var query: [String:String]    // ej: ["userId":"123"]
    public var namespace: String         // "/" o "/messages" (solo SI)
    public var mode: CompatMode
    public var plainMap: PlainMap
    public var connectTimeout: TimeInterval

    public init(baseURL: URL,
                path: String = "/QA/chat/socket",
                query: [String:String] = [:],
                namespace: String = "/",
                mode: CompatMode = .auto,
                plainMap: PlainMap = .init(),
                connectTimeout: TimeInterval = 6.0) {
        self.baseURL = baseURL
        self.path = path
        self.query = query
        self.namespace = namespace
        self.mode = mode
        self.plainMap = plainMap
        self.connectTimeout = connectTimeout
    }
}
