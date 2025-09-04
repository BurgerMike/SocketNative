//
//  Enum.swift
//  SocketNativo
//
//  Created by Miguel Carlos Elizondo Martinez on 04/09/25.
//

import Foundation

public enum CompatMode {
    case socketIO      // Engine.IO + Socket.IO v4
    case plainWS       // WebSocket puro {event,data}
    case auto          // intenta Socket.IO, cae a plainWS
}
