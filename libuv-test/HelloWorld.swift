//
//  HelloWorld.swift
//  libuv-test
//
//  Created by Chris Eidhof on 20/06/15.
//  Copyright © 2015 objc.io. All rights reserved.
//

import Foundation

import libuv

func main() {
    let loop = Loop()
    print("Now quitting")
    loop.run(UV_RUN_DEFAULT)
}