//
//  main.swift
//  libuv-test
//
//  Created by Chris Eidhof on 20/06/15.
//  Copyright © 2015 objc.io. All rights reserved.
//

import Foundation
import libuv

func helloWorld() {
    let loop: UnsafeMutablePointer<uv_loop_t> = UnsafeMutablePointer(malloc(sizeof(uv_loop_t)))
    uv_loop_init(loop)
    print("Now quitting")
    uv_run(loop, UV_RUN_DEFAULT)
    uv_loop_close(loop)
    free(loop)
}

private var counter: Int64 = 0 // Needs to be at the top-level
func idle() {
    let idler: UnsafeMutablePointer<uv_idle_t> = UnsafeMutablePointer(malloc(sizeof(uv_idle_t)))
    uv_idle_init(uv_default_loop(), idler)
    uv_idle_start(idler) { x in
        counter++
        if counter >= 10000000 {
            uv_idle_stop(x)
        }
    }
    print("Idling")
    uv_run(uv_default_loop(), UV_RUN_DEFAULT)
    uv_loop_close(uv_default_loop())
    free(idler)
}

//idle()

let numConnections = 10

let loop = uv_default_loop()

func printErr(errorCode: Int) {
    let strError = uv_strerror(Int32(errorCode))
    let str = String(CString: strError, encoding: NSUTF8StringEncoding)
    print("Error \(errorCode): \(str)")
}

let echo_read: uv_read_cb = { server, nread, buf in
    guard nread >= 0 else {
        printErr(nread); return
}
    let req = UnsafeMutablePointer<uv_write_t>.alloc(sizeof(uv_write_t))
    print("bytes read: \(nread)")
    uv_write(req, server, buf, 1, nil)
    free(buf.memory.base)
}
let alloc_buffer: uv_alloc_cb = { (handle: UnsafeMutablePointer<uv_handle_t>, suggestedSize: Int, buffer: UnsafeMutablePointer<uv_buf_t>) in
    print("suggested size \(suggestedSize)")
    buffer.memory = uv_buf_init(UnsafeMutablePointer.alloc(suggestedSize), UInt32(suggestedSize))
}

typealias Loop = UnsafeMutablePointer<uv_loop_t>
typealias Address = UnsafeMutablePointer<sockaddr_in>

class TCP {
    let server = UnsafeMutablePointer<uv_tcp_t>.alloc(1)
    
    init(loop: Loop = uv_default_loop()) {
        uv_tcp_init(loop, server)
    }
    
    func bind(address: Address) {
        uv_tcp_bind(server, UnsafePointer(address), 0)
    }
    
    deinit {
        free(server)
    }
}

typealias StreamType = UnsafeMutablePointer<uv_stream_t>

protocol Stream {
    var stream: StreamType { get }
}

extension TCP: Stream {
    var stream: StreamType { return UnsafeMutablePointer(server) }
}


func tcpServer() {
    let server = TCP()

    let addr = UnsafeMutablePointer<sockaddr_in>(malloc(sizeof(sockaddr_in)))
    defer { free(addr) }

    uv_ip4_addr("0.0.0.0", 8888, addr)
    server.bind(addr)
    let on_new_connection: uv_connection_cb =  { server, status in
        if status < 0 {
            let strError = uv_strerror(status)
            print("New connection error: \(strError)")
        }
        let client = UnsafeMutablePointer<uv_tcp_t>(malloc(sizeof(uv_tcp_t)))
        uv_tcp_init(loop, client)
        if uv_accept(server, UnsafeMutablePointer(client)) == 0 {
            uv_read_start(UnsafeMutablePointer(client), alloc_buffer, echo_read)
        } else {
            uv_close(UnsafeMutablePointer(client), nil)
        }
    }

    let r = uv_listen(server.stream, Int32(numConnections), on_new_connection)
    guard r == 0 else {
        print("error"); return
    }
    uv_run(loop, UV_RUN_DEFAULT)
}

tcpServer()