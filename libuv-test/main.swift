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

let loop = uv_default_loop()

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
        free(addr)
    }
}

private let alloc_buffer: uv_alloc_cb = { (handle: UnsafeMutablePointer<uv_handle_t>, suggestedSize: Int, buffer: UnsafeMutablePointer<uv_buf_t>) in
    buffer.memory = uv_buf_init(UnsafeMutablePointer.alloc(suggestedSize), UInt32(suggestedSize))
}




@objc class Stream {
    var stream: StreamRef
    
    init(_ stream: StreamRef) {
        self.stream = stream
    }

    func accept(client: Stream) throws -> () {
        let result = uv_accept(stream, client.stream)
        if result < 0 { throw UVError.Error(code: result) }
    }
    
    func readStart(callback: uv_read_cb) throws {
        let result = uv_read_start(stream, alloc_buffer, callback)
        if result < 0 { throw UVError.Error(code: result) }
    }
}

typealias ReadBlock = (stream: Stream, data: NSData) -> ()
typealias ListenBlock = (stream: Stream, Int) -> ()

@objc class StreamContext {
    var readBlock: ReadBlock?
    var listenBlock: ListenBlock?
}

extension Stream {

    var context: StreamContext {
        get {
            let data = stream.memory.data
            if data == nil {
                let result = StreamContext()
                self.context = result
                return result
            }
            return Unmanaged<StreamContext>.fromOpaque(COpaquePointer(data)).takeUnretainedValue()
        }
        set {
            stream.memory.data = UnsafeMutablePointer(Unmanaged.passRetained(newValue).toOpaque())
        }
    }


    func read(callback: ReadBlock) throws {
        context.readBlock = callback
        let myCallback: uv_read_cb = { serverStream, bytesRead, buf in
            let stream = Stream(serverStream)
            if (bytesRead < 0) {
                stream.context.readBlock = nil
                stream.close()
                return
            }
            let data = NSData(bytes: buf.memory.base, length: bytesRead)
            stream.context.readBlock?(stream: stream, data: data)

        }
        uv_read_start(stream, alloc_buffer, myCallback)
    }
    
    func listen(numConnections: Int, callback: uv_connection_cb) throws -> () {
        let result = uv_listen(stream, Int32(numConnections), callback)
        if result < 0 {
            throw UVError.Error(code: result)
        }
    }
    
    func listen(numConnections: Int, theCallback: (Stream, Int) -> ()) throws -> () {
        context.listenBlock = theCallback
        let my_callback: uv_connection_cb = { serverStream, status in
            let stream = Stream(serverStream)
            let z = stream.context.listenBlock
            z?(stream: stream, Int(status))
            return ()
        }
        try listen(numConnections, callback: my_callback)
    }

    func write(buffer: BufferRef) {
        let req = Write()
        req.writeAndFree(self, buffer: buffer)
    }

    func close() {
        uv_close(UnsafeMutablePointer(stream), nil)
    }
}

class Write {
    var writeRef: WriteRef = WriteRef.alloc(1)
    
    func writeAndFree(stream: Stream, buffer: BufferRef) {
        assert(writeRef != nil)
        uv_write(writeRef, stream.stream, buffer, 1, { x, _ in
            free(x)
        })
    }
}

class TCP {
    let server = UnsafeMutablePointer<uv_tcp_t>.alloc(1)

    lazy var stream: Stream = Stream(UnsafeMutablePointer(self.server))

    var freeWhenDone: Bool


    init(loop: LoopRef = uv_default_loop(), freeWhenDone: Bool = false) {
        uv_tcp_init(loop, server)
        self.freeWhenDone = freeWhenDone
    }

    func bind(address: Address) {
        uv_tcp_bind(server, address.address, 0)
    }

    func close() {
        stream.close()
    }

    deinit {
        if freeWhenDone { free(server) }
    }
}

extension NSData {
    func bufferRef(callback: BufferRef -> ()) -> () {
        let count = length / sizeof(Int8)
        var buffer: [Int8] = [Int8](count: count, repeatedValue: 0)
        getBytes(&buffer, length: length)
        var z = uv_buf_init(&buffer, UInt32(count))
        withUnsafePointer(&z, callback)
    }
}

let echo_read: uv_read_cb = { serverStream, bytesRead, buf in
    let server = Stream(serverStream)
    
    if Int32(bytesRead) == UV_EOF.rawValue {
        server.close()
        return
    }
    
    guard bytesRead > 0 else {
        server.close()
        printErr(bytesRead); return
    }

    server.write(buf)
    
    free(buf.memory.base)
}

func tcpServer() throws {
    let server = TCP(freeWhenDone: true)

    let addr = Address(host: "0.0.0.0", port: 8888)
    server.bind(addr)
    var count = 0
    let on_new_connection: ListenBlock = { server, status in
        if status < 0 { printErr(Int(status)) }
        let client = TCP(freeWhenDone: true)
        do {
            try server.accept(client.stream)
            try client.stream.read { stream, data in
                count++
                guard let str: NSString = NSString(data: data, encoding: NSUTF8StringEncoding) else { return }
                let data = str.dataUsingEncoding(NSUTF8StringEncoding)
                data?.bufferRef { ref in
                    stream.write(ref)
                }
                print("Read: \(str)")
                client.close()
            }
        } catch {
            print("Caught \(error)")
            client.close()
        }
    }

    try server.stream.listen(numConnections, theCallback: on_new_connection)
    uv_run(loop, UV_RUN_DEFAULT)
}

do {
    try tcpServer()
} catch {
    print(error)
}