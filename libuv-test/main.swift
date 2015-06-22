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

@objc class Callback {
    var readBlock: ReadBlock?
    var listenBlock: ListenBlock?
}

extension Stream {

    var context: Callback {
        get {
            let data = stream.memory.data
            if data == nil {
                self.context = Callback()
                return self.context
            }
            let u: Unmanaged<Callback> = Unmanaged.fromOpaque(COpaquePointer(data))
            return u.takeUnretainedValue()
        }
        set {
            var s = stream.memory
            let u = Unmanaged.passRetained(newValue)
            s.data = UnsafeMutablePointer(u.toOpaque())
            stream.memory = s
            // TODO this never gets released.
        }
    }

    func read(callback: ReadBlock) throws {
        context.readBlock = callback
        let myCallback: uv_read_cb = { serverStream, bytesRead, buf in
            let stream = Stream(serverStream)
            stream.context.readBlock?(stream: stream, data: NSData())
            if (bytesRead < 0) {
                stream.context.readBlock = nil
                stream.close()
            }
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

    func close() {
        uv_close(UnsafeMutablePointer(stream), nil)
    }
}

class Write {
    var writeRef: WriteRef = WriteRef.alloc(1)
    
    func writeAndFree(stream: Stream, buffer: UnsafePointer<uv_buf_t>) {
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
    
    let req = Write()
    req.writeAndFree(server, buffer: buf)
    
    free(buf.memory.base)
}

func tcpServer() throws {
    let server = TCP(freeWhenDone: true)

    let addr = Address(host: "0.0.0.0", port: 8888)
    server.bind(addr)
    var count = 0
    let on_new_connection: ListenBlock = { server, status in
        if status < 0 { printErr(Int(status)) }
        let client = TCP()
        do {
            try server.accept(client.stream)
            try client.stream.read { data in
                count++
                print("Read!!! \(count)")
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