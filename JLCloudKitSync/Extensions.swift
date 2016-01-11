//
//  Extensions.swift
//  JLCloudKitSync
//
//  Created by Linghua Zhang on 2016/01/11.
//  Copyright © 2016年 Linghua Zhang. All rights reserved.
//

import Foundation

func <(lhs: NSDate, rhs: NSDate) -> Bool {
    return lhs.timeIntervalSinceReferenceDate < rhs.timeIntervalSinceReferenceDate
}
func >(lhs: NSDate, rhs: NSDate) -> Bool {
    return lhs.timeIntervalSinceReferenceDate > rhs.timeIntervalSinceReferenceDate
}

func AsyncOnMainQueue(block: dispatch_block_t) {
    dispatch_async(dispatch_get_main_queue(), block)
}