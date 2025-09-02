# SocketNativo

**SocketNativo** es un paquete Swift **100% nativo** (sin dependencias externas) que unifica:
- Un **núcleo** de conexión WebSocket/Engine.IO (tipo Socket.IO).
- Una **fachada en español** de alto nivel (`ChatNativo`) lista para apps de chat/juego con estados en vivo.
- **API de escuchas** tipo `onAny` (`enCualquierEvento`) y por evento (`escuchar`).

> Objetivo: reemplazar `Socket.IO-Client-Swift` por un **solo package** con API clara en español.

---

## Requisitos

- Xcode 15+
- Swift 5.9+
- iOS 16+ (usa `@Observation`/`@MainActor`).  
  > Si necesitas iOS 15, puedes cambiar la fachada a `ObservableObject` sin `@Observable`.

---

## Estructura

```
SocketNativo/
├─ Package.swift
└─ Sources/
   └─ SocketNativo/
      ├─ Core/                  # Tu núcleo: SocketClient, NamespaceChannel, etc.
      └─ Public/                # Fachada en español (ya incluida)
         ├─ Configuracion.swift
         ├─ Modelos.swift
         ├─ EmisorEscrituraLocal.swift
         └─ ChatNativo.swift
```

> Pon tus fuentes del **Core** en `Sources/SocketNativo/Core/`. La carpeta `Public/` ya viene lista.

---

## Instalación (Swift Package Manager)

### Opción A) Desde tu GitHub

1. Abre **Xcode → File → Add Packages…**
2. Ingresa la URL de tu repo, por ejemplo:
   ```text
   https://github.com/tu-org/SocketIO_Nativo.git
   ```
3. Selecciona el producto **SocketNativo**.

### Opción B) Local (ZIP / carpeta)

1. Coloca el folder del paquete en cualquier ruta local.
2. **Xcode → File → Add Packages… → Add Local…** y selecciona el `Package.swift`.

> Si actualizas el package: **File → Packages → Reset Package Caches** y luego **Product → Clean Build Folder** (⇧⌘K).

---

## Uso rápido

```swift
import SocketNativo

@MainActor
final class ChatVM {
    private let chat = ChatNativo()

    func iniciar() async {
        var cfg = ConfiguracionSocket(baseHTTP: URL(string: "http://localhost:3001")!)
        cfg.ruta = "/socket.io/"                 // o el prefijo de tu proxy: "/QA/chat/socket.io/"

        await chat.conectar(cfg,
                            namespace: "/messages",
                            idUsuario: 42,
                            idGrupo: 7)

        // Escuchar TODOS los eventos (tipo onAny)
        _ = chat.enCualquierEvento { (nombre: String, args: [Any]) in
            print("Evento:", nombre, "→", args)
        }
    }

    func enviar(_ texto: String) async {
        await chat.enviar(texto)
    }
}
```

---

## API (fachada en español)

### Conexión

```swift
await chat.conectar(cfg,
                    namespace: "/messages",
                    idUsuario: userId,
                    idGrupo: groupId)
```

- **`ConfiguracionSocket`**
  - `baseHTTP`: `http(s)://…` (se transforma a `ws(s)`)
  - `ruta`: por defecto `"/socket.io/"`. Puedes usar `"/QA/chat/socket.io/"` si tu backend está detrás de un proxy.
  - `queryExtra`: params adicionales si tu server los requiere (además de `EIO=4` y `transport=websocket`).

### Envío / Lecturas

```swift
await chat.enviar("Hola")
await chat.marcarComoLeido()                  // con ACK interno; cae a emit simple si el ACK falla
await chat.cerrarChat(resuelto: true)        // emite "close-chat" con resolved
```

### “Escribiendo…” (typing)

```swift
chat.entradaEditada()           // Llama en onChange del TextField, hace debounce
await chat.escribiendo(false)   // Para forzar apagado (al limpiar el input, por ejemplo)
```

### Presencia (iOS)

```swift
await chat.actualizarPresencia(true)   // online
await chat.actualizarPresencia(false)  // offline
```

> La fachada también registra observadores de app foreground/background (si está disponible) para que puedas actualizar presencia fácilmente.

### Escuchas / Eventos (tipo Socket.IO)

- **Todos los eventos** (equivalente a `onAny`):
  ```swift
  let tokenAny = chat.enCualquierEvento { (nombre: String, args: [Any]) in
      print(nombre, args)
  }
  chat.quitarEscuchaAny(id: tokenAny)
  ```

- **Por evento** (por ejemplo, `"receiveMessage"` y `"userTyping"`):
  ```swift
  let tokMsg = chat.escuchar("receiveMessage") { args in
      if let d = args.first as? [String: Any] {
          print("Mensaje:", d)
      }
  }

  let tokTyping = chat.escuchar("userTyping") { args in
      if let d = args.first as? [String: Any] {
          print("Typing:", d)
      }
  }

  chat.quitarEscucha("receiveMessage", id: tokMsg)
  chat.quitarEscucha("userTyping", id: tokTyping)
  ```

> Internamente, la fachada mantiene un puente por evento (`instalarPuente`) y reenvía a tus listeners **sin** bloquearte el hilo principal.

---

## Ejemplo SwiftUI (rápido)

```swift
import SwiftUI
import SocketNativo

struct ChatView: View {
    @State private var vm = ChatVM()
    @State private var texto = ""

    var body: some View {
        VStack {
            TextField("Escribe…", text: $texto)
                .onChange(of: texto) { _, t in
                    if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        vm.typing(true)
                    } else {
                        Task { await vm.typing(false) }
                    }
                }

            Button("Enviar") {
                Task { await vm.enviar(texto); texto = "" }
            }
            .disabled(texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task { await vm.iniciar() }
    }
}

@MainActor
final class ChatVM {
    private let chat = ChatNativo()

    func iniciar() async {
        var cfg = ConfiguracionSocket(baseHTTP: URL(string: "http://localhost:3001")!)
        cfg.ruta = "/socket.io/"
        await chat.conectar(cfg, namespace: "/messages", idUsuario: 1, idGrupo: 7)
    }

    func enviar(_ t: String) async { await chat.enviar(t) }
    func typing(_ on: Bool) { on ? chat.entradaEditada() : Task { await chat.escribiendo(false) } }
}
```

---

## Eventos esperados del servidor (convención)

- `start-chat` (emitido al conectar): `{ "groupId": Int }`
- `sendMessage` (emit): `{ "groupId": Int, "content": String }`
- `receiveMessage` (on): `{"messageId": Int, "userId": Int, "groupId": Int, "username": String, "content": String, "sentAt": ISO8601, "isCustomer": Bool/Int, "status": String}`
- `userTyping` (emit/on): `{"isTyping": Bool, "userId": Int}`
- `markMessagesAsRead` (emit/ack): `{"groupId": Int}`
- `close-chat` (emit): `{"groupId": Int, "resolved": Bool}`
- `presence:update` (emit): `{"userId": Int, "online": Bool}`

> Adapta los nombres/formatos a tu backend si difiere. La fachada es flexible.

---

## Migración desde `Socket.IO-Client-Swift`

- **Quita** `import SocketIO` y cualquier `SocketManager/SocketIOClient`.
- **Importa** `SocketNativo` y usa `ChatNativo`.
- Reemplaza tus `socket.on("evento")` por:
  - `escuchar("evento") { args in … }` o
  - `enCualquierEvento { nombre, args in … }`.

**Errores típicos al migrar y solución:**
- `Call to main actor-isolated …`: Anota tu VM con `@MainActor`.
- `Value of type 'ChatNativo' has no member 'enCualquierEvento'`: Estás en una versión vieja. Actualiza el package (o agrega las funciones de escuchas en `ChatNativo.swift`).  
- Cambiaste la ruta del socket (proxy): usa `cfg.ruta = "/QA/chat/socket.io/"`.

---

## Solución de problemas

- **No se conecta / no recibe eventos**  
  - Verifica `baseHTTP` (`http://` vs `https://`) y la `ruta` (`/socket.io/` o el prefijo real).
  - Asegúrate de que el *namespace* exista (por defecto `"/messages"`).
  - Revisa CORS/headers en tu backend.

- **“Archivo caducado” al importar ZIP**  
  - En Xcode: *File → Packages → Reset Package Caches* y *Product → Clean Build Folder* (⇧⌘K).
  - Vuelve a agregar el package (local o remoto).

- **UI no actualiza**  
  - Usa `@MainActor` en tu VM si tocas estado desde callbacks.
  - En SwiftUI, usa `@State`/`@StateObject` según tu patrón.  

---

## Licencia

MIT (o la que definas).

---

## Autoría / Contacto

- Equipo iOS — *Socket más nativo que el que hay* 😉
