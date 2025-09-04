//
//  Extensiones.swift
//  SocketNativo
//
//  Created by Miguel Carlos Elizondo Martinez on 04/09/25.
//

import Foundation

extension Engine {
    func dispatch(_ name: String, _ args: [Any]) {
        #if canImport(Dispatch)
        DispatchQueue.main.async { self.onAny?(name, args) }
        #else
        self.onAny?(name, args)
        #endif
    }
}
