import Foundation
public struct MensajeDeChat: Codable, Hashable, Sendable { public var id:String = UUID().uuidString; public var idUsuario:Int; public var idGrupo:Int; public var nombreUsuario:String; public var contenido:String; public var enviadoEnISO8601:String; public var esCliente:Bool; public var estado:String }
