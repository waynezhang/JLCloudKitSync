//
//  JLCloudKitSync.swift
//  JLCloudKitSync.h
//
//  Created by Linghua Zhang on 2015/03/13.
//  Copyright (c) 2015年 Linghua Zhang. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

public enum JLCloudKitFullSyncPolicy {
    case ReplaceDataOnCloudKit // Replace data on cloudkit with local data
    case ReplaceDataOnLocal // Replace data in local database with data in the cloud
}

public let JLCloudKitSyncWillBeginNotification = "JLCloudKitSyncWillBeginNotification"
public let JLCloudKitSyncDidEndNotification = "JLCloudKitSyncDidEndNotification"

public class JLCloudKitSync: NSObject {
    
    // Whether auto sync after local context is saved
    public var autoSyncOnSave: Bool = true
    
    private var context: NSManagedObjectContext!
    private var backingContext: NSManagedObjectContext!
    private var zoneName: String?
    private var zoneID: CKRecordZoneID {
        get { return CKRecordZoneID(zoneName: zoneName!, ownerName: CKOwnerDefaultName) }
    }
    
    // MARK: - APIs
    
    public init(context: NSManagedObjectContext) {
        self.context = context
        super.init()
        setupContextStack(context)
    }
    
    // Set work zone name, must be called before other APIs
    public func setupWorkZone(name: String, completionHandler: (NSError!) -> Void) {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: NSManagedObjectContextDidSaveNotification, object: self.context)
        
        let db = CKContainer.defaultContainer().privateCloudDatabase
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [ CKRecordZone(zoneName: name) ], recordZoneIDsToDelete: nil)
        operation.modifyRecordZonesCompletionBlock = { savedZones, _, error in
            self.info("Work Zone \( name ) save result: \( error )")
            self.zoneName = name

            NSNotificationCenter.defaultCenter().addObserver(self, selector: Selector("contextDidSave:"), name: NSManagedObjectContextDidSaveNotification, object: self.context)

            dispatch_async(dispatch_get_main_queue()) { completionHandler(error) }
        }
        db.addOperation(operation)
    }
    
    // Find if there is data in the cloud
    public func discoverEntities(recordType: String, completionHandler: (entitiesExist: Bool, error: NSError!) -> Void) {
        let db = CKContainer.defaultContainer().privateCloudDatabase
        var exists = false
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let operation = CKQueryOperation(query: query)
        operation.zoneID = self.zoneID
        operation.resultsLimit = 1
        operation.desiredKeys = [ ]
        operation.recordFetchedBlock = { exists = $0 != nil }
        operation.completionBlock = {
            dispatch_async(dispatch_get_main_queue()) {
                completionHandler(entitiesExist: exists, error: nil)
            }
        }
        db.addOperation(operation)
    }
    
    // Fully sync
    public func performFullSync(policy: JLCloudKitFullSyncPolicy) {
        self.notifySyncBegin()
        setPreviousToken(nil)
        
        switch policy {
        case .ReplaceDataOnCloudKit: performFullSyncFromLocal()
        case .ReplaceDataOnLocal: performFullSyncFromRemote()
        }
    }
    
    // Incremental sync
    public func performSync() {
        self.notifySyncBegin()
        self.performSyncInternal()
    }
    
    // Wipe cloud data and sync queue
    public func wipeDataInCloudKitAndCleanQueue(completionHandler: (NSError?) -> Void) {
        clearDataInCloudKit { error in
            self.clearData(self.backingContext, entityName: JLCloudKitItem.entityName())
            completionHandler(error)
        }
    }
    
    // Stop sync
    public func stopSync() {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: NSManagedObjectContextDidSaveNotification, object: self.context)
    }
    
    // MARK: - Sync

    // Full sync, replace data in local with cloud
    func performFullSyncFromRemote() {
        clearSyncQueue()
        clearDataInLocalContext()
        performSyncInternal()
    }
    
    func mergeServerChanges(changedRecords: [CKRecord], deleteRecordIDs: [CKRecordID]) {
        var changedRecordMappings:[CKRecordID:CKRecord] = changedRecords.reduce([:]) { (var map, record) in
            map[record.recordID] = record
            return map
        }

        var needProcessAgain:[(CKRecord, NSManagedObject, JLCloudKitItem)] = [ ]
        // modified
        for item in self.fetchSyncItems(changedRecordMappings.keys) {
            let record = changedRecordMappings[CKRecordID(recordName: item.recordID!, zoneID: zoneID)]!
            info("merge item \( item.lastModified! ) vs \( record.modificationDate )")
            if item.lastModified!.earlierDate(record.modificationDate).timeIntervalSinceDate(record.modificationDate) < 0 {
                // server record is newer
                let object = fetchLocalObjects([item.recordID!]).values.first!
                if updateLocalObjectWithRecord(object, record: record) {
                    updateSyncItem(item, object: object, status: .Clean, date: record.modificationDate, recordName: record.recordID.recordName!)
                } else {
                    needProcessAgain.append(record, object, item)
                }
            }
            changedRecordMappings.removeValueForKey(record.recordID)
        }
        
        // newly inserted
        for (recordID, record) in changedRecordMappings {
            info("insert item \( record.modificationDate )")
            let entities = context.persistentStoreCoordinator!.managedObjectModel.entities.filter { ($0 as! NSEntityDescription).name! == record.recordType }
            if entities.count == 0 {
                warn("entity \( record.recordType ) not exists")
                continue
            }
            let object = NSManagedObject(entity: entities[0] as! NSEntityDescription, insertIntoManagedObjectContext: context)
            let item = JLCloudKitItem(managedObjectContext: backingContext)
            context.obtainPermanentIDsForObjects([object], error: nil)
            if updateLocalObjectWithRecord(object, record: record) {
                updateSyncItem(item, object: object, status: .Clean, date: record.modificationDate, recordName: record.recordID.recordName!)
            } else {
                needProcessAgain.append(record, object, item)
            }
        }
        
        for (record, object, item) in needProcessAgain {
            info("process again \( record.recordType ), \( record.recordID.recordName )")
            updateLocalObjectWithRecord(object, record: record)
            updateSyncItem(item, object: object, status: .Clean, date: record.modificationDate, recordName: record.recordID.recordName!)
        }
        
        // deleted
        let deletedRecordIDStrings = deleteRecordIDs.map { $0.recordName! }
        removeLocalObject(deletedRecordIDStrings)
        removeFromSyncQueue(deletedRecordIDStrings)
        
        saveBackingContext()
        saveContext(context, name: "Content")
    }
    
    // Full sync, replace data in cloud with local
    func performFullSyncFromLocal() {
        wipeDataInCloudKitAndCleanQueue { err in
            self.addAllLocalDataToSyncQueue()
            self.saveBackingContext()
            self.performSyncInternal()
        }
    }
    
    // Sync
    func performSyncInternal() {
        var toSave: [JLCloudKitItem] = [ ]
        var toDelete: [CKRecordID] = [ ]
        
        let request = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        request.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.status.rawValue ) != %@", NSNumber(integer: JLCloudKitItemStatus.Clean.rawValue))
        if let items = backingContext.executeFetchRequest(request, error: nil) as? [JLCloudKitItem] {
            toSave.extend(items.filter { $0.status!.integerValue == JLCloudKitItemStatus.Dirty.rawValue })
            toDelete.extend(items
                .filter { $0.status!.integerValue == JLCloudKitItemStatus.Deleted.rawValue }
                .map { CKRecordID(recordName: $0.recordID!, zoneID: self.zoneID) })
        }
        info("sync queue \( toSave.count ) inserted, \( toDelete.count ) deleted")
        
        self.fetchOrCreateRecords(toSave) { records in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: toDelete)
            operation.modifyRecordsCompletionBlock = { saved, deleted, err in
                self.info("modifications applied to server, \( saved.count ) saved, \( deleted.count ) deleted,  error: \( err )")
                
                self.markSyncQueueClean(saved as! [CKRecord])
                self.removeFromSyncQueue(deleted.map { ($0 as! CKRecordID).recordName! })
                self.saveBackingContext()
                
                self.fetchServerChanges(self.previousToken(), completionHandler: {
                    self.mergeServerChanges($0, deleteRecordIDs: $1)
                    if ($2 != nil) {
                        self.setPreviousToken($2)
                    }
                    self.saveBackingContext()
                })
                
                self.notifySyncEnd(err)
            }
            operation.savePolicy = .IfServerRecordUnchanged
            CKContainer.defaultContainer().privateCloudDatabase.addOperation(operation)
        }
    }
    
    func fetchServerChanges(previousToken: CKServerChangeToken!, completionHandler: ([CKRecord], [CKRecordID], CKServerChangeToken!) -> Void) {
        var changed: [CKRecord] = [ ]
        var deleted: [CKRecordID] = [ ]

        let ope = CKFetchRecordChangesOperation(recordZoneID: zoneID, previousServerChangeToken: previousToken)
        ope.recordChangedBlock = { changed.append($0) }
        ope.recordWithIDWasDeletedBlock = { deleted.append($0) }
        ope.fetchRecordChangesCompletionBlock = { token, data, err in
            self.info("Server change: \( changed.count ) changed, \( deleted.count ) deleted \( err )")
            completionHandler(changed, deleted, token)
        }
        CKContainer.defaultContainer().privateCloudDatabase.addOperation(ope)
    }
    
    // MARK: - Sync Token
    
    func setPreviousToken(token: CKServerChangeToken?) {
        var object: NSManagedObject?
        let req = NSFetchRequest(entityName: metaEntityName)
        req.predicate = NSPredicate(format: "name = %@", "server_token")
        if let results = backingContext.executeFetchRequest(req, error: nil) {
            if results.count > 0 {
                object = results[0] as? NSManagedObject
            }
        }
        if object == nil {
            object = NSManagedObject(entity: NSEntityDescription.entityForName(metaEntityName, inManagedObjectContext: backingContext)!, insertIntoManagedObjectContext: backingContext)
            object!.setValue("server_token", forKey: "name")
        }
        if token != nil {
            let data = NSKeyedArchiver.archivedDataWithRootObject(token!)
            object!.setValue(data, forKey: "value")
        } else {
            backingContext.deleteObject(object!)
        }
    }
    
    func previousToken() -> CKServerChangeToken? {
        let req = NSFetchRequest(entityName: metaEntityName)
        req.predicate = NSPredicate(format: "name = %@", "server_token")
        if let results = backingContext.executeFetchRequest(req, error: nil) {
            if results.count > 0 {
                let object = results[0] as? NSManagedObject
                let data = object?.valueForKey("value") as? NSData
                if data != nil {
                    return NSKeyedUnarchiver.unarchiveObjectWithData(data!) as? CKServerChangeToken
                }
            }
        }
        return nil
    }

    // MARK: - Local Cache
    
    func contextDidSave(notification: NSNotification) {
        let inserted = addLocalObjectsToSyncQueue((notification.userInfo![NSInsertedObjectsKey] as? NSSet)?.allObjects as? [NSManagedObject], status: .Dirty)
        let updated = addLocalObjectsToSyncQueue((notification.userInfo![NSUpdatedObjectsKey] as? NSSet)?.allObjects as? [NSManagedObject], status: .Dirty)
        let deleted = addLocalObjectsToSyncQueue((notification.userInfo![NSDeletedObjectsKey] as? NSSet)?.allObjects as? [NSManagedObject], status: .Deleted)
        info("context changed, \( inserted ) inserted, \( updated ) updated, \( deleted )")
        
        self.saveBackingContext()
        if self.autoSyncOnSave {
            self.performSync()
        }
    }

    // Map local objects to sync items
    func addLocalObjectsToSyncQueue<T: SequenceType where T.Generator.Element: NSManagedObject>(set: T?, status: JLCloudKitItemStatus) -> Int {
        if set == nil { return 0 }

        return reduce(set!, 0) { (count, object) in
            var item = self.fetchSyncItem(object.objectID)
            if item == nil {
                item = JLCloudKitItem(managedObjectContext: self.backingContext)
            }
            self.updateSyncItem(item!, object: object, status: status)
            
            return count + 1
        }
    }
    
    func removeLocalObject(recordIDs: [String]) {
        let objects = self.fetchLocalObjects(recordIDs)
        for (_, object) in objects {
            self.context.deleteObject(object)
        }
    }

    // MARK: - Mapping
    
    // MARK: Local Objects to CKRecord

    // Map a single local object to record
    func updateRecordWithLocalObject(record: CKRecord, object: NSManagedObject) {
        for (k, _) in object.entity.attributesByName as! [String:AnyObject] {
            record.setValue(object.valueForKey(k), forKey: k)
        }
        for (name, rel) in object.entity.relationshipsByName as! [String:NSRelationshipDescription] {
            if rel.toMany {
                // ignore
            } else {
                if let relObj = object.valueForKey(name) as? NSManagedObject {
                    if let recordName = self.fetchRecordName(relObj.objectID) {
                        let recordID = CKRecordID(recordName: recordName, zoneID: self.zoneID)
                        let ref = CKReference(recordID: recordID, action: CKReferenceAction.DeleteSelf)
                        record.setObject(ref, forKey: name)
                    } else {
                        warn("Can not find \( name ) for \( object )")
                    }
                }
            }
        }
    }
    
    // Create a new record and set values from a local object
    func recordWithLocalObject(recordName: String, object: NSManagedObject) -> CKRecord {
        let id = CKRecordID(recordName: recordName, zoneID: self.zoneID)
        let record = CKRecord(recordType: object.entity.name!, recordID: id)
        updateRecordWithLocalObject(record, object: object)
        return record
    }
    
    // Map all local objects to records, modified on exist ones, or newly created if necessary
    func fetchOrCreateRecords(syncItems: [JLCloudKitItem], completionBlock: ([CKRecord]) -> Void) {
        var syncItemMappings:[String:JLCloudKitItem] = syncItems.reduce([:]) { (var map, item) in
            map[item.recordID!] = item
            return map
        }
        let recordIDs = syncItems.map { $0.recordID! }
        var objects = fetchLocalObjects(recordIDs)
        var records: [CKRecord] = [ ]
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs.map { CKRecordID(recordName: $0, zoneID: self.zoneID) })
        operation.fetchRecordsCompletionBlock = { results, err in
            for (recordID, record) in results as! [ CKRecordID: CKRecord ] {
                let item = syncItemMappings[recordID.recordName!]!
                let object = objects.removeValueForKey(recordID.recordName)!
                if item.lastModified!.earlierDate(record.modificationDate) == record.modificationDate {
                    // newer than server
                    self.updateRecordWithLocalObject(record, object: object)
                    records.append(record)
                }
            }
            for (recordName, object) in objects {
                records.append(self.recordWithLocalObject(recordName, object: object))
            }
            completionBlock(records)
        }
        CKContainer.defaultContainer().privateCloudDatabase.addOperation(operation)
    }
    
    // Get record name by local object id
    func fetchRecordName(managedObjectID: NSManagedObjectID) -> String? {
        return fetchSyncItem(managedObjectID)?.recordID
    }
    
    // MARK: Local Objects to Sync Item
    
    func addAllLocalDataToSyncQueue() {
        var count = 0
        for e in context.persistentStoreCoordinator!.managedObjectModel.entities as! [NSEntityDescription] {
            let req = NSFetchRequest(entityName: e.name!)
            req.predicate = NSPredicate(value: true)
            let results = context.executeFetchRequest(req, error: nil) as? [NSManagedObject]
            count += addLocalObjectsToSyncQueue(results, status: .Dirty)
        }
        info("\( count ) items added to sync queue")
    }
    
    // MARK: CKRecord to Local Objects
    
    // Map a single record to local object
    func updateLocalObjectWithRecord(object: NSManagedObject, record: CKRecord) -> Bool {
        var clean = true
        
        for (k, _) in object.entity.attributesByName as! [String:AnyObject] {
            object.setValue(record.valueForKey(k), forKey: k)
        }
        for (name, rel) in object.entity.relationshipsByName as! [String:NSRelationshipDescription] {
            if rel.toMany {
                // ignore
            } else {
                if let refObj = record.valueForKey(name) as? CKReference {
                    let relatedObjects = fetchLocalObjects([ refObj.recordID.recordName! ])
                    if relatedObjects.count > 0 {
                        // related object exists
                        let relObj = relatedObjects.values.first!
                        object.setValue(relObj, forKey: name)
                    } else {
                        info("related \( name ) object not found")
                        clean = false
                    }
                }
            }
        }
        
        return clean
    }
    
    func fetchLocalObjects(recordIDs: [String]) -> [String : NSManagedObject] {
        var objects: [String : NSManagedObject] = [ : ]
        let req = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        req.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.recordID.rawValue ) IN %@", recordIDs)
        if let results = self.backingContext.executeFetchRequest(req, error: nil) {
            for item in results as! [JLCloudKitItem] {
                let objectID = context.persistentStoreCoordinator!.managedObjectIDForURIRepresentation(NSURL(string: item.localObjectID! as String)!)
                if let obj = context.existingObjectWithID(objectID!, error: nil) {
                    objects[item.recordID!] = obj
                } else {
                    warn("object no exists any more \( item.recordID! )")
                }
            }
        }
        return objects
    }
    
    // MARK: CKRecord to Sync Items
    
    func fetchSyncItems<T: SequenceType where T.Generator.Element: CKRecordID>(recordIDs: T) -> [JLCloudKitItem] {
        let recordNames = map(recordIDs) { $0.recordName! }
        let request = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        request.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.recordID.rawValue ) IN %@", recordNames)
        if let results = backingContext.executeFetchRequest(request, error: nil) {
            return results as! [JLCloudKitItem]
        }
        return [ ]
    }
    
    // MARK: Local Object to Sync Item
    
    func fetchSyncItem(managedObjectID: NSManagedObjectID) -> JLCloudKitItem? {
        let request = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        request.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.localObjectID.rawValue ) = %@", managedObjectID.URIRepresentation())
        if let results = backingContext.executeFetchRequest(request, error: nil) {
            if results.count > 0 {
                return results[0] as? JLCloudKitItem
            }
        }
        return nil
    }
    
    func updateSyncItem(item: JLCloudKitItem, object: NSManagedObject, status: JLCloudKitItemStatus, date: NSDate = NSDate(), recordName: String? = nil) {
        if item.valueForKey(JLCloudKitItemAttribute.recordID.rawValue) == nil {
            if recordName == nil {
                item.setValue(NSUUID().UUIDString, forKey: JLCloudKitItemAttribute.recordID.rawValue)
            } else {
                item.setValue(recordName!, forKey: JLCloudKitItemAttribute.recordID.rawValue)
            }
        }
        item.setValue(object.objectID.URIRepresentation().absoluteString!, forKey: JLCloudKitItemAttribute.localObjectID.rawValue)
        item.setValue(object.entity.name, forKey: JLCloudKitItemAttribute.type.rawValue)
        item.setValue(NSDate(), forKey: JLCloudKitItemAttribute.lastModified.rawValue)
        item.setValue(NSNumber(integer: status.rawValue), forKey: JLCloudKitItemAttribute.status.rawValue)
    }
    
    // MARK: - Setup
    
    func setupContextStack(context: NSManagedObjectContext) {
        backingContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        
        let model = generateModel()
        let persistentCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        if let store = persistentCoordinator.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: storeURL(), options: nil, error: nil) {
            info("Store added to \( storeURL() )")
        }
        backingContext.persistentStoreCoordinator = persistentCoordinator
    }
    
    func generateModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = JLCloudKitItem.entityName()
        entity.managedObjectClassName = JLCloudKitItem.entityName()

        let ckIDAttr = NSAttributeDescription()
        ckIDAttr.name = JLCloudKitItemAttribute.recordID.rawValue
        ckIDAttr.attributeType = .StringAttributeType
        ckIDAttr.indexed = true
        
        let localIDAttr = NSAttributeDescription()
        localIDAttr.name = JLCloudKitItemAttribute.localObjectID.rawValue
        localIDAttr.attributeType = .StringAttributeType
        localIDAttr.indexed = true
        
        let typeAttr = NSAttributeDescription()
        typeAttr.name = JLCloudKitItemAttribute.type.rawValue
        typeAttr.attributeType = .StringAttributeType
        
        let lastModifiedAttr = NSAttributeDescription()
        lastModifiedAttr.name = JLCloudKitItemAttribute.lastModified.rawValue
        lastModifiedAttr.attributeType = .DateAttributeType
        
        let statusAttr = NSAttributeDescription()
        statusAttr.name = JLCloudKitItemAttribute.status.rawValue
        statusAttr.attributeType = .Integer16AttributeType
        statusAttr.indexed = true
        
        entity.properties = [ ckIDAttr, localIDAttr, typeAttr, lastModifiedAttr, statusAttr ]
        
        let metaEntity = NSEntityDescription()
        metaEntity.name = metaEntityName
        let metaNameAttr = NSAttributeDescription()
        metaNameAttr.name = "name"
        metaNameAttr.attributeType = .StringAttributeType
        metaNameAttr.indexed = true
        let metaValueAttr = NSAttributeDescription()
        metaValueAttr.name = "value"
        metaValueAttr.attributeType = .BinaryDataAttributeType
        metaEntity.properties = [ metaNameAttr, metaValueAttr ]
        
        model.entities = [ entity, metaEntity ]
        return model
    }
    
    let metaEntityName: String = "JTCloudKitMeta"
    
    func storeURL() -> NSURL {
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        let url = urls.last! as! NSURL
        return url.URLByAppendingPathComponent("JLCloudKitSync.sqlite")
    }
    
    // MARK: - Utilities
    
    func saveBackingContext() {
        saveContext(backingContext, name: "Backing")
    }
    
    func saveContext(context: NSManagedObjectContext, name: String) {
        context.performBlockAndWait {
            var error: NSError?
            if context.hasChanges {
                context.save(&error)
                self.info("\( name ) context saved \( error )")
            }
        }
    }
    
    public func clearSyncQueue() { clearData(backingContext, entityName: JLCloudKitItem.entityName()) }
    
    func clearDataInCloudKit(completionHandler: (NSError!) -> Void) {
        let db = CKContainer.defaultContainer().privateCloudDatabase
        db.deleteRecordZoneWithID(self.zoneID) { zoneID, error in
            self.info("Zone \( self.zoneName! ) cleared result \( error )")
            self.setupWorkZone( self.zoneName!, completionHandler: completionHandler)
        }
    }
    
    func clearDataInLocalContext() {
        for e in context.persistentStoreCoordinator!.managedObjectModel.entities as! [NSEntityDescription] {
            clearData(context, entityName: e.name!)
        }
    }
    
    func clearData(context: NSManagedObjectContext, entityName: String) {
        let req = NSFetchRequest(entityName: entityName)
        if let results = context.executeFetchRequest(req, error: nil) {
            for obj in results {
                context.deleteObject(obj as! NSManagedObject)
            }
        }
    }
    
    func removeFromSyncQueue(recordIDs: [String]) {
        let req = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        req.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.recordID.rawValue ) IN %@", recordIDs)
        if let results = backingContext.executeFetchRequest(req, error: nil) {
            for item in results as! [NSManagedObject] {
                backingContext.deleteObject(item)
            }
        }
    }
    
    func markSyncQueueClean(records: [CKRecord]) {
        let items = fetchSyncItems(records.map { $0.recordID })
        let recordMappings:[CKRecordID:CKRecord] = records.reduce([:]) { (var map, record) in
            map[record.recordID] = record
            return map
        }
        for item in items {
            let recordID = CKRecordID(recordName: item.recordID!, zoneID: zoneID)
            let record = recordMappings[recordID]!
            item.lastModified = record.modificationDate
            item.status = NSNumber(integer: JLCloudKitItemStatus.Clean.rawValue)
        }
    }
    
    func notifySyncBegin() {
        dispatch_async(dispatch_get_main_queue()) {
            NSNotificationCenter.defaultCenter().postNotificationName(JLCloudKitSyncWillBeginNotification, object: nil)
        }
    }
    
    func notifySyncEnd(error: NSError?) {
        dispatch_async(dispatch_get_main_queue()) {
            var info: [NSObject: AnyObject] = [ : ]
            if error != nil { info["error"] = error }
            NSNotificationCenter.defaultCenter().postNotificationName(JLCloudKitSyncDidEndNotification, object: nil, userInfo: info)
        }
    }
}