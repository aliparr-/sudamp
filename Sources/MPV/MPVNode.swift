// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Libmpv

/// A Sendable copy of an `mpv_node` (DESIGN §5.2: everything leaving the event thread is a value type).
public indirect enum MPVNode: Sendable, Equatable, Hashable, CustomStringConvertible {
    case none
    case string(String)
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case array([MPVNode])
    case map([String: MPVNode])

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Numeric value; integers convert.
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e18: return Int64(d)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .flag(let b) = self { return b }
        return nil
    }

    public var array: [MPVNode]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var map: [String: MPVNode]? {
        if case .map(let m) = self { return m }
        return nil
    }

    public subscript(key: String) -> MPVNode? { map?[key] }

    public var description: String {
        switch self {
        case .none: return "none"
        case .string(let s): return s
        case .flag(let b): return b ? "yes" : "no"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .map(let m): return "{" + m.keys.sorted().map { "\($0): \(m[$0]!.description)" }.joined(separator: ", ") + "}"
        }
    }
}

extension MPVNode {
    /// Deep-copies a C node (the caller still owns and frees it).
    init(_ node: mpv_node) {
        switch node.format {
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            self = node.u.string.map { .string(String(cString: $0)) } ?? .none
        case MPV_FORMAT_FLAG:
            self = .flag(node.u.flag != 0)
        case MPV_FORMAT_INT64:
            self = .int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            self = .double(node.u.double_)
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee, let values = list.values else { self = .array([]); return }
            self = .array((0..<Int(list.num)).map { MPVNode(values[$0]) })
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values, let keys = list.keys else {
                self = .map([:])
                return
            }
            var out: [String: MPVNode] = [:]
            for i in 0..<Int(list.num) {
                if let key = keys[i] { out[String(cString: key)] = MPVNode(values[i]) }
            }
            self = .map(out)
        default:
            self = .none
        }
    }

    /// Builds a C node tree for the duration of `body`. libmpv copies what it needs (async commands included),
    /// so the tree is freed afterwards.
    func withCNode<R>(_ body: (UnsafeMutablePointer<mpv_node>) throws -> R) rethrows -> R {
        let arena = CNodeArena()
        let root = arena.allocateNodes(1)
        arena.fill(root, self)
        return try body(root)
    }
}

/// Owns every allocation of one C node tree.
private final class CNodeArena {
    private var allocations: [UnsafeMutableRawPointer] = []

    deinit {
        for p in allocations { free(p) }
    }

    func allocateNodes(_ count: Int) -> UnsafeMutablePointer<mpv_node> {
        let raw = calloc(max(count, 1), MemoryLayout<mpv_node>.stride)!
        allocations.append(raw)
        return raw.bindMemory(to: mpv_node.self, capacity: max(count, 1))
    }

    func duplicate(_ s: String) -> UnsafeMutablePointer<CChar> {
        let p = strdup(s)!
        allocations.append(UnsafeMutableRawPointer(p))
        return p
    }

    func fill(_ dst: UnsafeMutablePointer<mpv_node>, _ node: MPVNode) {
        switch node {
        case .none:
            dst.pointee.format = MPV_FORMAT_NONE
        case .string(let s):
            dst.pointee.format = MPV_FORMAT_STRING
            dst.pointee.u.string = duplicate(s)
        case .flag(let b):
            dst.pointee.format = MPV_FORMAT_FLAG
            dst.pointee.u.flag = b ? 1 : 0
        case .int(let i):
            dst.pointee.format = MPV_FORMAT_INT64
            dst.pointee.u.int64 = i
        case .double(let d):
            dst.pointee.format = MPV_FORMAT_DOUBLE
            dst.pointee.u.double_ = d
        case .array(let items):
            dst.pointee.format = MPV_FORMAT_NODE_ARRAY
            dst.pointee.u.list = makeList(values: items, keys: nil)
        case .map(let dict):
            let keys = dict.keys.sorted()
            dst.pointee.format = MPV_FORMAT_NODE_MAP
            dst.pointee.u.list = makeList(values: keys.map { dict[$0]! }, keys: keys)
        }
    }

    private func makeList(values: [MPVNode], keys: [String]?) -> UnsafeMutablePointer<mpv_node_list> {
        let rawList = calloc(1, MemoryLayout<mpv_node_list>.stride)!
        allocations.append(rawList)
        let list = rawList.bindMemory(to: mpv_node_list.self, capacity: 1)
        let nodes = allocateNodes(values.count)
        for (i, v) in values.enumerated() { fill(nodes + i, v) }
        list.pointee.num = Int32(values.count)
        list.pointee.values = nodes
        if let keys {
            let rawKeys = calloc(max(keys.count, 1), MemoryLayout<UnsafeMutablePointer<CChar>?>.stride)!
            allocations.append(rawKeys)
            let keyArray = rawKeys.bindMemory(to: UnsafeMutablePointer<CChar>?.self, capacity: max(keys.count, 1))
            for (i, k) in keys.enumerated() { keyArray[i] = duplicate(k) }
            list.pointee.keys = keyArray
        }
        return list
    }
}
