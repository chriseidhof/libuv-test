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
    let loop: UnsafeMutablePointer<uv_loop_t>
    
    init(loop: UnsafeMutablePointer<uv_loop_t> = UnsafeMutablePointer.alloc(1)) {
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
        print("Dealloc addr")
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
    
    func listen(numConnections: Int, callback: uv_connection_cb) throws -> () {
        let result = uv_listen(stream, Int32(numConnections), callback)
        if result < 0 { throw UVError.Error(code: result) }
    }
    
    func closeAndFree() {
        uv_close(UnsafeMutablePointer(stream)) { handle in
            free(handle)
        }
    }
}

typealias ReadBlock = (stream: Stream, data: NSData?) -> ()
typealias ListenBlock = (serverStream: Stream, Int) -> ()

@objc class StreamContext {
    var readBlock: ReadBlock?
    var listenBlock: ListenBlock?
}

private func alloc_buffer(_: UnsafeMutablePointer<uv_handle_t>, suggestedSize: Int, buffer: UnsafeMutablePointer<uv_buf_t>) -> () {
    buffer.memory = uv_buf_init(UnsafeMutablePointer.alloc(suggestedSize), UInt32(suggestedSize))
}

private func free_buffer(buffer: UnsafePointer<uv_buf_t>) {
    print("Freeing buffer")
    free(buffer.memory.base)
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
            // TODO dealloc this
            guard stream.memory.data == nil else { fatalError("Cannot set stream twice") }
            
            stream.memory.data = UnsafeMutablePointer(Unmanaged.passRetained(newValue).toOpaque())
        }
    }


    func read(callback: ReadBlock) throws {
        context.readBlock = callback
        uv_read_start(stream, alloc_buffer) {
            serverStream, bytesRead, buf in
            defer { free_buffer(buf) }
            let stream = Stream(serverStream)
            print("bytes read: \(bytesRead)")
            
            if (bytesRead == Int(UV_EOF.rawValue)) { // EOF
                stream.context.readBlock?(stream: stream, data: nil)
                stream.context.readBlock = nil
                return
            } else if (bytesRead < 0) { // Error
                let err = UVError.Error(code: Int32(bytesRead))
                fatalError(err.description)
            }
            let data = NSData(bytes: buf.memory.base, length: bytesRead)
            stream.context.readBlock?(stream: stream, data: data)
        }

    }
    
    func listen(numConnections: Int, theCallback: (Stream, Int) -> ()) throws -> () {
        context.listenBlock = theCallback
        try listen(numConnections, callback: { serverStream, status in
            let stream = Stream(serverStream)
            stream.context.listenBlock?(serverStream: stream, Int(status))
        })
    }

    func write(completion: () -> ())(buffer: BufferRef) {
        Write().writeAndFree(self, buffer: buffer, completion: completion)
    }
    
}

@objc class WriteCompletionHandler {
    var completion: () -> ()
    init(_ c: () -> ()) {
        completion = c
    }
}

class Write {
    var writeRef: WriteRef = WriteRef.alloc(1) // dealloced in the write callback
    
    func writeAndFree(stream: Stream, buffer: BufferRef, completion: () -> ()) {
        assert(writeRef != nil)
        
        writeRef.memory.data =
            UnsafeMutablePointer(Unmanaged.passRetained(WriteCompletionHandler(completion)).toOpaque())
        uv_write(writeRef, stream.stream, buffer, 1, { x, _ in
            let completionHandler = Unmanaged<WriteCompletionHandler>.fromOpaque(COpaquePointer(x.memory.data)).takeRetainedValue().completion
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

func TCPServer(handleRequest: (Stream, NSData, () -> ()) -> ()) throws {
    let server = TCP()

    let addr = Address(host: "0.0.0.0", port: 8888)
    server.bind(addr)
//    let on_new_connection: ListenBlock = { serverStream, status in
//        if status < 0 { printErr(Int(status)) }
//        let client = TCP()
//        do {
//            try serverStream.accept(client)
//            let mutableData = NSMutableData()
//            try client.read { stream, data in
//                if let data = data {
//                    mutableData.appendData(data)
//                } else {
//                    handleRequest(stream, mutableData) {
//                        client.closeAndFree()
//                    }
//                }
//            }
//        } catch {
//            print("Caught \(error)")
//            client.closeAndFree()
//        }
//    }
//
//    try server.listen(numConnections, theCallback: on_new_connection)
    try server.listen(numConnections, callback: { stream, status in
        let server = Stream(stream)
        let client = TCP()
        try! server.accept(client)
        client.closeAndFree()
    })
    Loop.defaultLoop.run(UV_RUN_DEFAULT)
}

func tcpServer() throws {
    try TCPServer() { stream, data, completion in
        guard let str: NSString = NSString(data: data, encoding: NSUTF8StringEncoding) else { return }
        if let data = str.stringByAppendingString("World").dataUsingEncoding(NSUTF8StringEncoding) {
            stream.writeData(data) {
                print("write completion")
                completion()
            }
        }
    }
}

do {
//    main()
//    print("Done")
    try tcpServer()
} catch {
    print(error)
}