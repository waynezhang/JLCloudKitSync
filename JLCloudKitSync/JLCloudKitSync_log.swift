//
//  JLCloudKitSync_log.swift
//  JLCloudKitSync
//
//  Created by Linghua Zhang on 2015/03/16.
//  Copyright (c) 2015年 Linghua Zhang. All rights reserved.
//

import Foundation
import ObjectiveC

internal extension JLCloudKitSync {
    func info(message: String) {
        log("INFO", message: message)
    }
    
    func warn(message: String) {
        log("WARN", message: message)
    }
    
    func err(message: String) {
        log("ERROR", message: message)
    }
    
    func log(type: String, message: String) {
        println("[\(type)] JLCloudKitSync: " + message)
    }
}