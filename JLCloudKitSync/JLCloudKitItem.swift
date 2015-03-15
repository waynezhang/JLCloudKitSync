//
//  JLCloudKitItem.swift
//  JLCloudKitSync
//
//  Created by Linghua Zhang on 2015/03/15.
//  Copyright (c) 2015年 Linghua Zhang. All rights reserved.
//

import Foundation
import CoreData

enum JLCloudKitItemAttribute: String {
    case type = "type"
    case recordID = "recordID"
    case localObjectID = "localObjectID"
    case lastModified = "lastModified"
    case status = "status"
}

enum JLCloudKitItemStatus: Int {
    case Clean = 0
    case Dirty = 1
    case Deleted = 2
}

@objc(JLCloudKitItem)
class JLCloudKitItem: NSManagedObject {
    
    class func entityName () -> String { return "JLCloudKitItem" }
    
    class func entity(managedObjectContext: NSManagedObjectContext!) -> NSEntityDescription! {
        return NSEntityDescription.entityForName(self.entityName(), inManagedObjectContext: managedObjectContext);
    }
    
    convenience init(managedObjectContext: NSManagedObjectContext!) {
        let entity = JLCloudKitItem.entity(managedObjectContext)
        self.init(entity: entity, insertIntoManagedObjectContext: managedObjectContext)
    }
    
    @NSManaged var type: String?
    @NSManaged var recordID: String?
    @NSManaged var lastModified: NSDate?
    @NSManaged var status: NSNumber?
    @NSManaged var localObjectID: NSString?
}