//
//  JLCloudKitSyncTests.swift
//  JLCloudKitSyncTests
//
//  Created by Linghua Zhang on 2015/03/16.
//  Copyright (c) 2015年 Linghua Zhang. All rights reserved.
//

import UIKit
import XCTest
import CoreData
import CloudKit
import JLCloudKitSync

//@objc class Group: NSManagedObject {
//    class func entityName () -> String { return "Group" }
//    class func entity(managedObjectContext: NSManagedObjectContext!) -> NSEntityDescription! {
//        return NSEntityDescription.entityForName(self.entityName(), inManagedObjectContext: managedObjectContext);
//    }
//    convenience init(managedObjectContext: NSManagedObjectContext!) {
//        let entity = Group.entity(managedObjectContext)
//        self.init(entity: entity, insertIntoManagedObjectContext: managedObjectContext)
//    }
//    @NSManaged var name: String?
//    @NSManaged var items: NSSet
//}
//
//@objc class Item: NSManagedObject {
//    class func entityName () -> String { return "Item" }
//    class func entity(managedObjectContext: NSManagedObjectContext!) -> NSEntityDescription! {
//        return NSEntityDescription.entityForName(self.entityName(), inManagedObjectContext: managedObjectContext);
//    }
//    convenience init(managedObjectContext: NSManagedObjectContext!) {
//        let entity = Item.entity(managedObjectContext)
//        self.init(entity: entity, insertIntoManagedObjectContext: managedObjectContext)
//    }
//    @NSManaged var name: String?
//    @NSManaged var group: Group?
//}

class JLCloudKitSyncTests: XCTestCase {
    
    var syncer: JLCloudKitSync!
    var context: NSManagedObjectContext!
    let zoneName = "JLCloudKitSync"
    
    override func setUp() {
        super.setUp()
        self.context = self.managedObjectContext!

        self.reloadData()
        
        XCTAssertEqual(countOfEntity("Group"), 1, "")
        XCTAssertEqual(countOfEntity("Item"), 5, "")
        
        syncer = JLCloudKitSync(context: context)
        syncer.clearSyncQueue()
        
        let ex = self.expectationWithDescription("")
        syncer.setupWorkZone(zoneName, completionHandler: { error -> Void in
            XCTAssertNil(error, "")
            ex.fulfill()
        })
        self.waitForExpectationsWithTimeout(5, handler: nil)
        self.recreateRecordZone(zoneName)
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    func testAA() {
        self.createGroupRecord("test group")
    }
    
    func testDiscovery() {
        let ex1 = self.expectationWithDescription("")
        syncer.discoverEntities("Group") { (exists, error) -> Void in
            XCTAssertFalse(exists, "")
            ex1.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
        
        self.createGroupRecord("test group")
        sleep(3)
        let ex2 = self.expectationWithDescription("")
        syncer.discoverEntities("Group") { (exists, error) -> Void in
            XCTAssertTrue(exists, "")
            ex2.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func testPerformFullSyncLocal() {
        createGroupRecord("Group 2")
        sleep(3)
        ensureGroupExists("Group 2", exists: true)
        ensureGroupExists("Group 1", exists: false)
        ensureItemExists("Item 1", hasGroup: "", exists: false)
        
        let ex = self.expectationForNotification(JLCloudKitSyncDidEndNotification, object: nil, handler: nil)
        syncer.performFullSync(JLCloudKitFullSyncPolicy.ReplaceDataOnCloudKit)
        self.waitForExpectationsWithTimeout(5, handler: nil)
        
        ensureGroupExists("Group 2", exists: false)
        sleep(3)
        ensureGroupExists("Group 1", exists: true)
        ensureItemExists("Item 1", hasGroup: "Group 1", exists: true)
    }
    
    func testPerformFullSyncRemote() {
        createItemRecord("Item 21", group: "Group 2")

        sleep(3)
        ensureGroupExists("Group 2", exists: true)
        ensureItemExists("Item 21", hasGroup: "Group 2", exists: true)
        ensureGroupExists("Group 1", exists: false)
        ensureItemExists("Item 1", hasGroup: "", exists: false)
        
        let ex = self.expectationForNotification(JLCloudKitSyncDidEndNotification, object: nil, handler: nil)
        syncer.performFullSync(JLCloudKitFullSyncPolicy.ReplaceDataOnLocal)
        self.waitForExpectationsWithTimeout(50, handler: nil)
        
        sleep(3)
        ensureGroupExists("Group 2", exists: true)
        ensureItemExists("Item 21", hasGroup: "Group 2", exists: true)
        ensureGroupExists("Group 1", exists: false)
        ensureItemExists("Item 1", hasGroup: "", exists: false)

        let item = fetchLocalObject("Item 21", entityName: "Item")
        XCTAssertNotNil(item, "")
        XCTAssertNotNil(item?.valueForKey("group"), "")
        
        let group = fetchLocalObject("Group 2", entityName: "Group")
        XCTAssertNotNil(group, "")

        XCTAssertEqual((item!.valueForKey("group")! as! NSManagedObject).objectID, group!.objectID, "")
        
        group!.setValue("Group 3", forKey: "name")
        let ex1 = self.expectationForNotification(JLCloudKitSyncDidEndNotification, object: nil, handler: nil)
        saveContext()
        self.waitForExpectationsWithTimeout(50, handler: nil)
        sleep(3)
        ensureGroupExists("Group 3", exists: true)
        ensureGroupExists("Group 2", exists: false)
    }
    
    func testSync() {
        let group = groupWithName("Group 2")
        let item = itemWithName("Item 11", group: group)
        
        let ex1 = self.expectationForNotification(JLCloudKitSyncDidEndNotification, object: nil, handler: nil)
        self.saveContext()
        self.waitForExpectationsWithTimeout(10, handler: nil)
        
        sleep(3)
        ensureGroupExists("Group 2", exists: true)
        ensureItemExists("Item 11", hasGroup: "Group 2", exists: true)
        
        let ex2 = self.expectationForNotification(JLCloudKitSyncDidEndNotification, object: nil, handler: nil)
        item.setValue("Item 22", forKey: "name")
        self.saveContext()
        self.waitForExpectationsWithTimeout(5, handler: nil)
        
        sleep(3)
        ensureItemExists("Item 11", hasGroup: "", exists: false)
        ensureItemExists("Item 22", hasGroup: "Group 2", exists: true)
    }
    
    // MARK: - Utility
    
    func zoneID() -> CKRecordZoneID {
        return CKRecordZoneID(zoneName: zoneName, ownerName: CKOwnerDefaultName)
    }
    
    func ensureGroupExists(name: String, exists: Bool) {
        let ex = self.expectationWithDescription("")
        let query = CKQuery(recordType: "Group", predicate: NSPredicate(format: "name = %@", name))
        CKContainer.defaultContainer().privateCloudDatabase.performQuery(query, inZoneWithID: zoneID()) { records, error -> Void in
            XCTAssertNil(error, "")
            XCTAssertEqual(exists, records != nil && records!.count == 1, "")
            ex.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func ensureItemExists(name: String, hasGroup group: String, exists: Bool) {
        let ex = self.expectationWithDescription("")
        let query = CKQuery(recordType: "Item", predicate: NSPredicate(format: "name = %@", name))
        CKContainer.defaultContainer().privateCloudDatabase.performQuery(query, inZoneWithID: zoneID()) { records, error -> Void in
            XCTAssertNil(error, "")
            XCTAssertEqual(exists, records != nil && records!.count == 1, "")
            if exists {
                XCTAssertNotNil(records![0].valueForKey("group") as? CKReference, "")
            }
            ex.fulfill()
        }
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func createGroupRecord(name: String) {
        let ex = self.expectationWithDescription("")
        let record = CKRecord(recordType: "Group", zoneID: zoneID())
        record.setValue(name, forKey: "name")
        CKContainer.defaultContainer().privateCloudDatabase.saveRecord(record, completionHandler: completionHandler(ex))
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func createItemRecord(name: String, group: String) {
        let ex = self.expectationWithDescription("")

        let record = CKRecord(recordType: "Item", zoneID: zoneID())
        record.setValue(name, forKey: "name")

        let groupRecord = CKRecord(recordType: "Group", zoneID: zoneID())
        groupRecord.setValue(group, forKey: "name")
        
        let ref = CKReference(recordID: groupRecord.recordID, action: CKReferenceAction.DeleteSelf)
        record.setValue(ref, forKey: "group")

        let operation = CKModifyRecordsOperation(recordsToSave: [ record, groupRecord ], recordIDsToDelete: nil)
        operation.completionBlock = {
            ex.fulfill()
        }
        CKContainer.defaultContainer().privateCloudDatabase.addOperation(operation)
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func recreateRecordZone(name: String) {
        deleteRecordZone(name)
        createRecordZone(name)
    }
    
    func createRecordZone(name: String) {
        let ex = self.expectationWithDescription("")
        let zone = CKRecordZone(zoneName: name)
        CKContainer.defaultContainer().privateCloudDatabase.saveRecordZone(zone, completionHandler: completionHandler(ex))
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func deleteRecordZone(name: String) {
        let ex = self.expectationWithDescription("")
        let zoneID = CKRecordZoneID(zoneName: name, ownerName: CKOwnerDefaultName)
        CKContainer.defaultContainer().privateCloudDatabase.deleteRecordZoneWithID(zoneID, completionHandler: completionHandler(ex))
        self.waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func completionHandler<T>(expectation: XCTestExpectation) -> ((T, NSError?) -> Void) {
        return { _, error in
            XCTAssertNil(error, "")
            expectation.fulfill()
        }
    }
    
    func fetchLocalObject(name: String, entityName: String) -> NSManagedObject? {
        let req = NSFetchRequest(entityName: entityName)
        req.predicate = NSPredicate(format: "name = %@", name)
        if let rs = try? context.executeFetchRequest(req) {
            if rs.count > 0 {
                return rs[0] as? NSManagedObject
            }
        }
        return nil
    }
    
    func deleteAllObject(name: String) {
        let req = NSFetchRequest(entityName: name)
        req.predicate = NSPredicate(value: true)
        if let rs = try? self.context.executeFetchRequest(req) {
            for e in rs {
                self.context.deleteObject(e as! NSManagedObject)
            }
        }
    }
    
    func reloadData() {
        self.deleteAllObject("Group")
        self.deleteAllObject("Item")
        
        let group = groupWithName("Group 1")
        for i in 1...5 {
            itemWithName("Item \( i )", group: group)
        }
        self.context.performBlockAndWait { () -> Void in
            var err: NSError?
            do {
                try self.context.save()
            } catch let error as NSError {
                err = error
            } catch {
                fatalError()
            }
        }
    }
    
    func groupWithName(name: String) -> NSManagedObject {
        return objectWithEntity("Group", name: name)
    }

    func itemWithName(name: String, group: NSManagedObject) -> NSManagedObject {
        let object = objectWithEntity("Item", name: name)
        object.setValue(group, forKey: "group")
        return object
    }
    
    func objectWithEntity(entityName: String, name: String) -> NSManagedObject {
        let object = NSManagedObject(entity: NSEntityDescription.entityForName(entityName, inManagedObjectContext: context)!, insertIntoManagedObjectContext: context)
        object.setValue(name, forKey: "name")
        return object
    }
    
    func countOfEntity(name: String) -> Int {
        let req = NSFetchRequest(entityName: name)
        req.includesSubentities = false
        req.predicate = NSPredicate(value: true)
        return self.context.countForFetchRequest(req, error: nil)
    }
    
    lazy var applicationDocumentsDirectory: NSURL = {
        // The directory the application uses to store the Core Data store file. This code uses a directory named "com.cesariapp.ios.JLCloudKitSyncTestsHost" in the application's documents Application Support directory.
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        return urls[urls.count-1] 
        }()
    
    lazy var managedObjectModel: NSManagedObjectModel = {
        // The managed object model for the application. This property is not optional. It is a fatal error for the application not to be able to find and load its model.
        let modelURL = NSBundle.mainBundle().URLForResource("JLCloudKitSyncTestsHost", withExtension: "momd")!
        return NSManagedObjectModel(contentsOfURL: modelURL)!
        }()
    
    lazy var persistentStoreCoordinator: NSPersistentStoreCoordinator? = {
        // The persistent store coordinator for the application. This implementation creates and return a coordinator, having added the store for the application to it. This property is optional since there are legitimate error conditions that could cause the creation of the store to fail.
        // Create the coordinator and store
        var coordinator: NSPersistentStoreCoordinator? = NSPersistentStoreCoordinator(managedObjectModel: self.managedObjectModel)
        let url = self.applicationDocumentsDirectory.URLByAppendingPathComponent("JLCloudKitSyncTestsHost.sqlite")
        print("host database \( url )")
        do {
            try NSFileManager.defaultManager().removeItemAtURL(url)
        } catch _ {
        }
        
        var error: NSError? = nil
        var failureReason = "There was an error creating or loading the application's saved data."
        do {
            try coordinator!.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: url, options: nil)
        } catch var error1 as NSError {
            error = error1
            coordinator = nil
            // Report any error we got.
            var dict = [String: AnyObject]()
            dict[NSLocalizedDescriptionKey] = "Failed to initialize the application's saved data"
            dict[NSLocalizedFailureReasonErrorKey] = failureReason
            dict[NSUnderlyingErrorKey] = error
            error = NSError(domain: "YOUR_ERROR_DOMAIN", code: 9999, userInfo: dict)
            // Replace this with code to handle the error appropriately.
            // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            NSLog("Unresolved error \(error), \(error!.userInfo)")
            abort()
        } catch {
            fatalError()
        }
        
        return coordinator
        }()
    
    lazy var managedObjectContext: NSManagedObjectContext? = {
        // Returns the managed object context for the application (which is already bound to the persistent store coordinator for the application.) This property is optional since there are legitimate error conditions that could cause the creation of the context to fail.
        let coordinator = self.persistentStoreCoordinator
        if coordinator == nil {
            return nil
        }
        var managedObjectContext = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.PrivateQueueConcurrencyType)
        managedObjectContext.persistentStoreCoordinator = coordinator
        return managedObjectContext
        }()
    
    func saveContext() {
        self.context.performBlock { () -> Void in
            var err: NSError?
            do {
                try self.context.save()
            } catch let error as NSError {
                err = error
            } catch {
                fatalError()
            }
        }
    }
}
