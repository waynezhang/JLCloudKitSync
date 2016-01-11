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
    case type
    case recordID
    case localObjectID
    case lastModified
    case status
}

enum JLCloudKitItemStatus: Int {
    case Clean
    case Dirty
    case Deleted
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