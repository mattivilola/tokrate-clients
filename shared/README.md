# Shared client foundation

`Sources/TokrateCore` owns Codex parsing, normalized metrics, retention and the signed contribution protocol. `Sources/tokrate` is the command-line inspector; `Tests/TokrateCoreTests` validates those behaviors. The root Swift package connects these targets to the macOS app.

The current package is validated on macOS and uses Apple CryptoKit. Windows/Linux compatibility is not claimed. Future native clients can reuse compatible code or implement the same documented protocol without depending on the macOS UI or Keychain adapter.
