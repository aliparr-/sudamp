// SPDX-License-Identifier: GPL-3.0-or-later
import Libmpv

/// An mpv event converted on the event thread into a Sendable value.
public enum MPVEvent: Sendable {
    case log(MPVLogMessage)
    case propertyChange(name: String, value: MPVNode)
    case startFile(playlistEntryID: Int64)
    case fileLoaded
    case endFile(MPVEndFile)
    case playbackRestart
    case seek
    case idle
    case audioReconfig
    case commandReply(requestID: UInt64, error: Int32, result: MPVNode)
    case setPropertyReply(requestID: UInt64, error: Int32)
    case getPropertyReply(requestID: UInt64, error: Int32, name: String, value: MPVNode)
    case shutdown
    case other(id: Int32, name: String)
}

public struct MPVLogMessage: Sendable, Codable, Equatable {
    public var prefix: String
    public var level: String
    public var text: String
}

public struct MPVEndFile: Sendable, Codable, Equatable {
    public enum Reason: String, Sendable, Codable {
        case eof, stop, quit, error, redirect, unknown
    }

    public var reason: Reason
    /// mpv error code (negative) when `reason == .error`.
    public var error: Int32
    public var playlistEntryID: Int64

    public var errorDescription: String? { reason == .error ? MPVClient.errorString(error) : nil }
}

extension MPVEndFile.Reason {
    init(_ raw: mpv_end_file_reason) {
        switch raw {
        case MPV_END_FILE_REASON_EOF: self = .eof
        case MPV_END_FILE_REASON_STOP: self = .stop
        case MPV_END_FILE_REASON_QUIT: self = .quit
        case MPV_END_FILE_REASON_ERROR: self = .error
        case MPV_END_FILE_REASON_REDIRECT: self = .redirect
        default: self = .unknown
        }
    }
}

extension MPVEvent {
    /// Converts a raw event; must run before the next `mpv_wait_event` (the data is owned by mpv).
    init(_ event: mpv_event) {
        let data = event.data
        switch event.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            guard let m = data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else {
                self = .other(id: Int32(event.event_id.rawValue), name: "log-message")
                return
            }
            var text = m.text.map { String(cString: $0) } ?? ""
            while text.hasSuffix("\n") { text.removeLast() }
            self = .log(MPVLogMessage(prefix: m.prefix.map { String(cString: $0) } ?? "",
                                      level: m.level.map { String(cString: $0) } ?? "", text: text))
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let p = data?.assumingMemoryBound(to: mpv_event_property.self).pointee else {
                self = .other(id: Int32(event.event_id.rawValue), name: "property-change")
                return
            }
            self = .propertyChange(name: p.name.map { String(cString: $0) } ?? "", value: Self.value(of: p))
        case MPV_EVENT_START_FILE:
            let id = data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id ?? 0
            self = .startFile(playlistEntryID: id)
        case MPV_EVENT_FILE_LOADED:
            self = .fileLoaded
        case MPV_EVENT_END_FILE:
            if let e = data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                self = .endFile(MPVEndFile(reason: .init(e.reason), error: e.error, playlistEntryID: e.playlist_entry_id))
            } else {
                self = .endFile(MPVEndFile(reason: .unknown, error: 0, playlistEntryID: 0))
            }
        case MPV_EVENT_PLAYBACK_RESTART:
            self = .playbackRestart
        case MPV_EVENT_SEEK:
            self = .seek
        case MPV_EVENT_IDLE:
            self = .idle
        case MPV_EVENT_AUDIO_RECONFIG:
            self = .audioReconfig
        case MPV_EVENT_COMMAND_REPLY:
            let result = data?.assumingMemoryBound(to: mpv_event_command.self).pointee.result
            self = .commandReply(requestID: event.reply_userdata, error: event.error,
                                 result: result.map(MPVNode.init) ?? .none)
        case MPV_EVENT_SET_PROPERTY_REPLY:
            self = .setPropertyReply(requestID: event.reply_userdata, error: event.error)
        case MPV_EVENT_GET_PROPERTY_REPLY:
            let p = data?.assumingMemoryBound(to: mpv_event_property.self).pointee
            self = .getPropertyReply(requestID: event.reply_userdata, error: event.error,
                                     name: p?.name.map { String(cString: $0) } ?? "",
                                     value: p.map(Self.value(of:)) ?? .none)
        case MPV_EVENT_SHUTDOWN:
            self = .shutdown
        default:
            self = .other(id: Int32(event.event_id.rawValue), name: String(cString: mpv_event_name(event.event_id)))
        }
    }

    private static func value(of property: mpv_event_property) -> MPVNode {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_NODE: return MPVNode(data.assumingMemoryBound(to: mpv_node.self).pointee)
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            return data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.map { .string(String(cString: $0)) } ?? .none
        case MPV_FORMAT_FLAG: return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_INT64: return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_DOUBLE: return .double(data.assumingMemoryBound(to: Double.self).pointee)
        default: return .none
        }
    }
}
