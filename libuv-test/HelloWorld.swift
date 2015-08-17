//
//  HelloWorld.swift
//  libuv-test
//
//  Created by Chris Eidhof on 20/06/15.
//  Copyright © 2015 objc.io. All rights reserved.
//

import Foundation

import libuv

// <<LoopAndQuit>>
func loopAndQuit() {
    let loop = UnsafeMutablePointer<uv_loop_t>.alloc(1)
    defer { loop.dealloc(1) }

    uv_loop_init(loop)
    defer { uv_loop_close(loop) }

    print("Now quitting")
    uv_run(loop, UV_RUN_DEFAULT)
}
// <</LoopAndQuit>>


// <<NowQuitting>>
func main() {
    let loop = Loop()
    print("Now quitting")
    loop.run(UV_RUN_DEFAULT)
}
// <</NowQuitting>>

func context1() {
    /*
    // <<TCPBroken>>
    func TCPServer(handleRequest: (Stream, NSData, () -> ()) -> ()) throws {
        let server = TCP()
        let addr = Address(host: "0.0.0.0", port: 8888)
        server.bind(addr)
        try server.listen(backlog: numConnections, callback: { stream, status in
            let client = TCP()
            try! server.accept(client)
            client.closeAndFree()
        })
        Loop.defaultLoop.run(UV_RUN_DEFAULT)
    }
    // <</TCPBroken>>
    */
}

func context2() {
    // <<TCPExampleClose>>
    func TCPServer(handleRequest: (Stream, NSData, () -> ()) -> ()) throws {
        let server = TCP()
        let addr = Address(host: "0.0.0.0", port: 8888)
        server.bind(addr)
        try server.listen(backlog: numConnections, callback: { stream, status in
            let server = Stream(stream)
            let client = TCP()
            try! server.accept(client)
            client.closeAndFree()
        })
        Loop.defaultLoop.run(UV_RUN_DEFAULT)
    }
    // <</TCPExampleClose>>

}
