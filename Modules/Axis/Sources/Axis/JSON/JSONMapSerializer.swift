#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif

import CYAJL

public struct JSONMapSerializerError : Error, CustomStringConvertible {
    let reason: String

    public var description: String {
        return reason
    }
}

public final class JSONMapSerializer : MapSerializer {
    private var ordering: Bool
    private var buffer: String = ""
    private var bufferSize: Int = 0
    private typealias Body = (UnsafeBufferPointer<Byte>) throws -> Void

    private var handle: yajl_gen!

    public convenience init() {
        self.init(ordering: false)
    }

    public init(ordering: Bool) {
        self.ordering = ordering
        self.handle = yajl_gen_alloc(nil)
    }

    deinit {
        yajl_gen_free(handle)
    }

    public func serialize(_ map: Map, bufferSize: Int = 4096, body: Body) throws {
        yajl_gen_reset(handle, nil)
        self.bufferSize = bufferSize
        try generate(map, body: body)
        try write(body: body)
    }

    private func generate(_ value: Map, body: Body) throws {
        switch value {
        case .null:
            try generateNull()
        case .bool(let bool):
            try generate(bool)
        case .double(let double):
            try generate(double)
        case .int(let int):
            try generate(int)
        case .string(let string):
            try generate(string)
        case .array(let array):
            try generate(array, body: body)
        case .dictionary(let dictionary):
            try generate(dictionary, body: body)
        default:
            throw MapError.incompatibleType
        }

        try write(highwater: bufferSize, body: body)
    }

    private func generate(_ dictionary: [String: Map], body: Body) throws {
        var status = yajl_gen_status_ok

        status = yajl_gen_map_open(handle)
        try check(status: status)

        if ordering {
            for key in dictionary.keys.sorted() {
                try generate(key)
                try generate(dictionary[key]!, body: body)
            }
        } else {
            for (key, value) in dictionary {
                try generate(key)
                try generate(value, body: body)
            }
        }

        status = yajl_gen_map_close(handle)
        try check(status: status)
    }

    private func generate(_ array: [Map], body: Body) throws {
        var status = yajl_gen_status_ok

        status = yajl_gen_array_open(handle)
        try check(status: status)

        for value in array {
            try generate(value, body: body)
        }

        status = yajl_gen_array_close(handle)
        try check(status: status)
    }

    private func generateNull() throws {
        try check(status: yajl_gen_null(handle))
    }

    private func generate(_ string: String) throws {
        let status: yajl_gen_status

        if string.isEmpty {
            status = yajl_gen_string(handle, nil, 0)
        } else {
            status = string.withCString { cStringPointer in
                return cStringPointer.withMemoryRebound(to: UInt8.self, capacity: string.utf8.count) {
                    yajl_gen_string(self.handle, $0, string.utf8.count)
                }
            }
        }

        try check(status: status)
    }

    private func generate(_ bool: Bool) throws {
        try check(status: yajl_gen_bool(handle, (bool) ? 1 : 0))
    }

    private func generate(_ double: Double) throws {
        let string = double.description
        let status = string.withCString { pointer in
            return yajl_gen_number(self.handle, pointer, string.utf8.count)
        }
        try check(status: status)
    }

    private func generate(_ int: Int) throws {
        try check(status: yajl_gen_integer(handle, Int64(int)))
    }

    private func check(status: yajl_gen_status) throws {
        switch status {
        case yajl_gen_keys_must_be_strings:
            throw JSONMapSerializerError(reason: "Keys must be strings.")
        case yajl_max_depth_exceeded:
            throw JSONMapSerializerError(reason: "Max depth exceeded.")
        case yajl_gen_in_error_state:
            throw JSONMapSerializerError(reason: "In error state.")
        case yajl_gen_invalid_number:
            throw JSONMapSerializerError(reason: "Invalid number.")
        case yajl_gen_no_buf:
            throw JSONMapSerializerError(reason: "No buffer.")
        case yajl_gen_invalid_string:
            throw JSONMapSerializerError(reason: "Invalid string.")
        case yajl_gen_status_ok:
            break
        case yajl_gen_generation_complete:
            break
        default:
            throw JSONMapSerializerError(reason: "Unknown.")
        }
    }

    private func write(highwater: Int = 0, body: Body) throws {
        var buffer: UnsafePointer<UInt8>? = nil
        var bufferLength: Int = 0

        guard yajl_gen_get_buf(handle, &buffer, &bufferLength) == yajl_gen_status_ok else {
            throw JSONMapSerializerError(reason: "Could not get buffer.")
        }

        guard bufferLength >= highwater else {
            return
        }

        try body(UnsafeBufferPointer(start: buffer, count: bufferLength))
        yajl_gen_clear(handle)
    }
}
