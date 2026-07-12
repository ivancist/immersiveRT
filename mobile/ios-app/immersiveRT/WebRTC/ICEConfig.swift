import Foundation
import WebRTC

/// Maps the pair-ack payload's `ice_servers` JSON (decoded via
/// `SignalingEnvelope.iceServers`, `client/src/phone.ts` line 471) into
/// `[RTCIceServer]` for `RTCConfiguration.iceServers`.
///
/// Server shape (`server/src/room_registry.rs`): each entry is
/// `{ "urls": String, "username"?: String, "credential"?: String }` —
/// `urls` is always a single string on this server (never an array), a
/// STUN entry has no `username`/`credential`, and a TURN entry has both.
enum ICEConfig {

    /// Maps decoded `ice_servers` JSON entries into `[RTCIceServer]`.
    ///
    /// Defensive by design (T-06.2-05): a malformed entry (missing/non-string
    /// `urls`) is skipped rather than force-unwrapped, so a bad server
    /// payload never crashes the client. `nil`/empty input maps to `[]`.
    static func iceServers(from entries: [Any]?) -> [RTCIceServer] {
        guard let entries else { return [] }

        return entries.compactMap { entry -> RTCIceServer? in
            guard let dict = entry as? [String: Any],
                  let urls = dict["urls"] as? String else {
                return nil
            }
            let username = dict["username"] as? String
            let credential = dict["credential"] as? String
            return RTCIceServer(urlStrings: [urls], username: username, credential: credential)
        }
    }
}
