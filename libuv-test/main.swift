//
//  main.swift
//  libuv-test
//
//  Created by Chris Eidhof on 20/06/15.
//  Copyright © 2015 objc.io. All rights reserved.
//

import Foundation
import libuv

let numConnections = 10

func printErr(errorCode: Int) {
    let strError = uv_strerror(Int32(errorCode))
    let str = String(CString: strError, encoding: NSUTF8StringEncoding)
    print("Error \(errorCode): \(str)")
}

typealias LoopRef = UnsafeMutablePointer<uv_loop_t>
typealias HandleRef = UnsafeMutablePointer<uv_handle_t>
typealias StreamRef = UnsafeMutablePointer<uv_stream_t>
typealias WriteRef = UnsafeMutablePointer<uv_write_t>
typealias BufferRef = UnsafePointer<uv_buf_t>

class Loop {
    let loop: LoopRef
    
    init(loop: LoopRef = UnsafeMutablePointer.alloc(1)) {
        self.loop = loop
        uv_loop_init(loop)
    }
    
    func run(mode: uv_run_mode) {
        uv_run(loop, mode)
    }
    
    deinit {
        uv_loop_close(loop)
        loop.dealloc(1)
    }
    
    static var defaultLoop = Loop(loop: uv_default_loop())
}


enum UVError: ErrorType {
    case Error(code: Int32)
}

extension UVError : CustomStringConvertible {
    var description: String {
        switch self {
        case .Error(let code):
            return String(CString: uv_err_name(code), encoding: NSUTF8StringEncoding) ?? "Unknown error"
        }
    }
}




class Address {
    var addr = UnsafeMutablePointer<sockaddr_in>.alloc(1)
    
    var address: UnsafePointer<sockaddr> {
        return UnsafePointer(addr)
    }
    
    init(host: String, port: Int) {
        uv_ip4_addr(host, Int32(port), addr)
    }
    
    deinit {
        addr.dealloc(1)
    }
}

class Stream {
    var stream: StreamRef
    
    init(_ stream: StreamRef) {
        self.stream = stream
    }

    func accept(client: Stream) throws -> () {
        let result = uv_accept(stream, client.stream)
        if result < 0 { throw UVError.Error(code: result) }
    }
    
    func listen(backlog numConnections: Int, callback: uv_connection_cb) throws -> () {
        let result = uv_listen(stream, Int32(numConnections), callback)
        if result < 0 { throw UVError.Error(code: result) }
    }
    
    func closeAndFree() {
        uv_close(UnsafeMutablePointer(stream)) { handle in
            free(handle)
        }
    }
}

final class Box<A> {
    let unbox: A
    init(_ value: A) { unbox = value }
}

func retainedVoidPointer<A>(x: A?) -> UnsafeMutablePointer<Void> {
    guard let value = x else { return UnsafeMutablePointer() }
    let unmanaged = Unmanaged.passRetained(Box(value))
    return UnsafeMutablePointer(unmanaged.toOpaque())
}

func unsafeFromVoidPointer<A>(x: UnsafeMutablePointer<Void>) -> A? {
    guard x != nil else { return nil }
    return Unmanaged<Box<A>>.fromOpaque(COpaquePointer(x)).takeUnretainedValue().unbox
}

func releaseVoidPointer<A>(x: UnsafeMutablePointer<Void>) -> A? {
    guard x != nil else { return nil }
    return Unmanaged<Box<A>>.fromOpaque(COpaquePointer(x)).takeRetainedValue().unbox
}

typealias ReadBlock = ReadResult -> ()
typealias ListenBlock = (status: Int) -> ()

class StreamContext {
    var readBlock: ReadBlock?
    var listenBlock: ListenBlock?
}

private func alloc_buffer(_: UnsafeMutablePointer<uv_handle_t>, suggestedSize: Int, buffer: UnsafeMutablePointer<uv_buf_t>) -> () {
    buffer.memory = uv_buf_init(UnsafeMutablePointer.alloc(suggestedSize), UInt32(suggestedSize))
}

private func free_buffer(buffer: UnsafePointer<uv_buf_t>) {
    free(buffer.memory.base)
}

enum ReadResult {
    case Chunk(NSData)
    case EOF
    case Error(UVError)
}

extension Stream {
    var context: StreamContext {
        if _context == nil {
            _context = StreamContext()
        }
        return _context!
    }
    var _context: StreamContext? {
        get {
            return unsafeFromVoidPointer(stream.memory.data)
        }
        set {
            let _: StreamContext? = releaseVoidPointer(stream.memory.data)
            stream.memory.data = retainedVoidPointer(newValue)
        }
    }

    func read(callback: ReadBlock) throws {
        context.readBlock = callback
        uv_read_start(stream, alloc_buffer) { serverStream, bytesRead, buf in
            defer { free_buffer(buf) }
            let stream = Stream(serverStream)
            let data: ReadResult
            if (bytesRead == Int(UV_EOF.rawValue)) {
                data = .EOF
            } else if (bytesRead < 0) {
                data = .Error(UVError.Error(code: Int32(bytesRead)))
            } else {
                data = .Chunk(NSData(bytes: buf.memory.base, length: bytesRead))
            }
            stream.context.readBlock?(data)
        }
    }
    
    func listen(numConnections: Int, theCallback: ListenBlock) throws -> () {
        context.listenBlock = theCallback
        try listen(backlog: numConnections, callback: { serverStream, status in
            let stream = Stream(serverStream)
            stream.context.listenBlock?(status: Int(status))
        })
    }

    func write(completion: () -> ())(buffer: BufferRef) {
        Write().writeAndFree(self, buffer: buffer, completion: completion)
    }
    
}

class Write {
    var writeRef: WriteRef = WriteRef.alloc(1) // dealloced in the write callback
    
    func writeAndFree(stream: Stream, buffer: BufferRef, completion: () -> ()) {
        assert(writeRef != nil)
        
        writeRef.memory.data = retainedVoidPointer(completion)
        uv_write(writeRef, stream.stream, buffer, 1, { x, _ in
            let completionHandler: () -> () = releaseVoidPointer(x.memory.data)!
            free(x.memory.bufs)
            free(x)
            completionHandler()
        })
    }    
}

class TCP: Stream {
    let socket = UnsafeMutablePointer<uv_tcp_t>.alloc(1)

    init(loop: Loop = Loop.defaultLoop) {
        super.init(UnsafeMutablePointer(self.socket))
        uv_tcp_init(loop.loop, socket)
    }

    func bind(address: Address) {
        uv_tcp_bind(socket, address.address, 0)
    }
}

extension NSData {
    func withBufferRef(callback: BufferRef -> ()) -> () {
        let bytes = UnsafeMutablePointer<Int8>.alloc(length)
        getBytes(bytes, length: length)
        var data = uv_buf_init(bytes, UInt32(length))
        withUnsafePointer(&data, callback)
    }
}

extension Stream {
    func writeData(data: NSData, completion: () -> ()) {
        data.withBufferRef(write(completion))
    }
}

extension Stream {
    func bufferedRead(callback: NSData -> ()) throws -> () {
        let mutableData = NSMutableData()
        try read { [unowned self] result in
            if case let .Chunk(data) = result {
                mutableData.appendData(data)
            } else if case .EOF = result {
                callback(mutableData)
            } else {
                self.closeAndFree()
            }
        }
    }
}

extension Stream{
    func put(data: NSData) {
        writeData(data) {
            self.closeAndFree()
        }
    }}

typealias RequestHandler = (data: NSData, sink: NSData -> ()) -> ()

func runTCPServer(handleRequest: RequestHandler) throws {
    let server = TCP()
    let addr = Address(host: "0.0.0.0", port: 8888)
    server.bind(addr)
    try server.listen(numConnections) { status in
        guard status >= 0 else { return }
        let client = TCP()
        do {
            try server.accept(client)
            try client.bufferedRead { data in
                handleRequest(data: data, sink: client.put)
            }
        } catch {
            client.closeAndFree()
        }
    }
    Loop.defaultLoop.run(UV_RUN_DEFAULT)
}

extension String {
    func reverse() -> String {
        return self
    }
}

func run() throws {
    try runTCPServer() { data, sink in
        if let string = NSString(data: data, encoding: NSUTF8StringEncoding),
           let data = string.dataUsingEncoding(NSUTF8StringEncoding) {
            print(string)
            sink(data)
        }
    }
}

do {
    try run()
} catch {
    print(error)
}