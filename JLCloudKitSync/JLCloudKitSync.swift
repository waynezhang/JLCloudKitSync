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
    
    public typealias DiscoveryCompletionHandler = (entitiesExist: Bool, error: NSError?) -> Void
    
    // Whether auto sync after local context is saved
    public var autoSyncOnSave = true
    
    private var context: NSManagedObjectContext!
    private var backingContext: NSManagedObjectContext!
    private var zoneName: String?
    
    private let metaEntityName = "JTCloudKitMeta"
    
    private var zoneID: CKRecordZoneID {
        get { return CKRecordZoneID(zoneName: zoneName!, ownerName: CKOwnerDefaultName) }
    }
    
    private var previousToken: CKServerChangeToken? {
        set {
            var object: NSManagedObject?
            let req = NSFetchRequest(entityName: metaEntityName)
            req.predicate = NSPredicate(format: "name = %@", "server_token")
            
            if let results = try? backingContext.executeFetchRequest(req) where results.count > 0 {
                object = results.first as? NSManagedObject
            } else {
                let entity = NSEntityDescription.entityForName(metaEntityName, inManagedObjectContext: backingContext)
                object = NSManagedObject(entity: entity!, insertIntoManagedObjectContext: backingContext)
                object?.setValue("server_token", forKey: "name")
            }
            if newValue != nil {
                let data = NSKeyedArchiver.archivedDataWithRootObject(newValue!)
                object?.setValue(data, forKey: "value")
            } else {
                backingContext.deleteObject(object!)
            }
        }
        get {
            let req = NSFetchRequest(entityName: metaEntityName)
            req.predicate = NSPredicate(format: "name = %@", "server_token")
            if let
                results = try? backingContext.executeFetchRequest(req),
                object = results.first as? NSManagedObject,
                data = object.valueForKey("value") as? NSData,
                token = NSKeyedUnarchiver.unarchiveObjectWithData(data) as? CKServerChangeToken {
                    return token
            }
            return nil
        }
    }
    
    private lazy var storeURL: NSURL = {
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        let url = urls.last! 
        return url.URLByAppendingPathComponent("JLCloudKitSync.sqlite")
    }()
    
    // MARK: - APIs
    
    public init(context: NSManagedObjectContext) {
        self.context = context
        super.init()
        setupContextStack(context)
    }
    
    // Set work zone name, must be called before other APIs
    public func setupWorkZone(name: String, completionHandler: (NSError?) -> Void) {
        NSNotificationCenter.defaultCenter().removeObserver(self,
            name: NSManagedObjectContextDidSaveNotification,
            object: self.context)
        
        let zonesToSave = [ CKRecordZone(zoneName: name) ]
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: zonesToSave, recordZoneIDsToDelete: nil)
        operation.modifyRecordZonesCompletionBlock = { [unowned self] savedZones, _, error in
            self.info("Work Zone \( name ) save result: \( error )")
            self.zoneName = name

            NSNotificationCenter.defaultCenter().addObserver(self,
                selector: Selector("contextDidSave:"),
                name: NSManagedObjectContextDidSaveNotification,
                object: self.context)

            AsyncOnMainQueue { completionHandler(error) }
        }
        executeOperation(operation)
    }
    
    // Find if there is data in the cloud
    public func discoverEntities(recordType: String, completionHandler: DiscoveryCompletionHandler) {
        var exists = false
        
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let operation = CKQueryOperation(query: query)
        operation.zoneID = self.zoneID
        operation.resultsLimit = 1
        operation.desiredKeys = [ ]
        operation.recordFetchedBlock = { exists = $0 != nil }
        operation.completionBlock = {
            AsyncOnMainQueue { completionHandler(entitiesExist: exists, error: nil) }
        }
        executeOperation(operation)
    }
    
    // Fully sync
    public func performFullSync(policy: JLCloudKitFullSyncPolicy) {
        self.notifySyncBegin()
        self.previousToken = nil
        
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
        clearDataInCloudKit { [unowned self] error in
            self.clearData(self.backingContext, entityName: JLCloudKitItem.entityName())
            completionHandler(error)
        }
    }
    
    // Stop sync
    public func stopSync() {
        NSNotificationCenter.defaultCenter().removeObserver(self,
            name: NSManagedObjectContextDidSaveNotification,
            object: self.context)
    }
}

// MARK: - Sync
extension JLCloudKitSync {

    // Full sync, replace data in local with cloud
    private func performFullSyncFromRemote() {
        clearSyncQueue()
        clearDataInLocalContext()
        performSyncInternal()
    }
    
    // Full sync, replace data in cloud with local
    private func performFullSyncFromLocal() {
        wipeDataInCloudKitAndCleanQueue { [unowned self] _ in
            self.addAllLocalDataToSyncQueue()
            self.saveBackingContext()
            self.performSyncInternal()
        }
    }
    
    private func mergeServerChanges(changedRecords: [CKRecord], deleteRecordIDs: [CKRecordID]) {
        var changedRecordMappings = changedRecords.reduce([CKRecordID:CKRecord]()) { (var map, record) in
            map[record.recordID] = record
            return map
        }

        var needProcessAgain = [(CKRecord, NSManagedObject, JLCloudKitItem)]()
        
        // modified
        self.fetchSyncItems(changedRecordMappings.keys).forEach { item in
            let record = changedRecordMappings[CKRecordID(recordName: item.recordID!, zoneID: zoneID)]!
            info("merge item \(item.lastModified) vs \(record.modificationDate)")
            
            guard item.lastModified! < record.modificationDate! else { return }
            
            // server record is newer
            let object = fetchLocalObjects([item.recordID!]).values.first!
            if updateLocalObjectWithRecord(object, record: record) {
                updateSyncItem(item, object: object, status: .Clean, date: record.modificationDate!, recordName: record.recordID.recordName)
            } else {
                needProcessAgain.append(record, object, item)
            }
            changedRecordMappings.removeValueForKey(record.recordID)
        }
        
        // newly inserted
        changedRecordMappings.values.forEach { record in
            info("insert item \(record.modificationDate)")
            
            let entities = context.persistentStoreCoordinator!.managedObjectModel.entities.filter { ($0 ).name! == record.recordType }
            
            guard entities.count > 0 else {
                warn("entity \(record.recordType) not exists")
                return
            }
            
            let object = NSManagedObject(entity: entities[0] , insertIntoManagedObjectContext: context)
            let item = JLCloudKitItem(managedObjectContext: backingContext)
            
            _ = try? context.obtainPermanentIDsForObjects([object])
            
            if updateLocalObjectWithRecord(object, record: record) {
                updateSyncItem(item, object: object, status: .Clean, date: record.modificationDate!, recordName: record.recordID.recordName)
            } else {
                needProcessAgain.append(record, object, item)
            }
        }
        
        needProcessAgain.forEach { record, object, item in
            info("process again \(record.recordType), \(record.recordID.recordName)")
            updateLocalObjectWithRecord(object, record: record)
            updateSyncItem(item, object: object, status: .Clean, date: record.modificationDate!, recordName: record.recordID.recordName)
        }
        
        // deleted
        let deletedRecordIDStrings = deleteRecordIDs.map { $0.recordName }
        removeLocalObject(deletedRecordIDStrings)
        removeFromSyncQueue(deletedRecordIDStrings)
        
        saveBackingContext()
        saveContext(context, name: "Content")
    }
    
    
    // Sync
    private func performSyncInternal() {
        var toSave = [JLCloudKitItem]()
        var toDelete = [CKRecordID]()
        
        let request = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        request.predicate = NSPredicate(format: "\(JLCloudKitItemAttribute.status.rawValue) != %@",  JLCloudKitItemStatus.Clean.rawValue)
        if let items = (try? backingContext.executeFetchRequest(request)) as? [JLCloudKitItem] {
            toSave.appendContentsOf(items.filter { $0.status!.integerValue == JLCloudKitItemStatus.Dirty.rawValue })
            toDelete.appendContentsOf(items
                .filter { $0.status!.integerValue == JLCloudKitItemStatus.Deleted.rawValue }
                .map { CKRecordID(recordName: $0.recordID!, zoneID: self.zoneID) })
        }
        info("sync queue \( toSave.count ) inserted, \( toDelete.count ) deleted")
        
        self.fetchOrCreateRecords(toSave) { [unowned self] records in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: toDelete)
            operation.modifyRecordsCompletionBlock = { [unowned self] saved, deleted, err in
                self.info("modifications applied to server, \( saved?.count ?? 0 ) saved, \( deleted?.count ?? 0 ) deleted,  error: \( err )")
                
                self.markSyncQueueClean(saved ?? [ ])
                self.removeFromSyncQueue((deleted ?? [ ]).map { $0.recordName })
                self.saveBackingContext()
                
                self.fetchServerChanges (self.previousToken) { [unowned self] changedRecords, deletedIDs, serverToken in
                    self.mergeServerChanges(changedRecords, deleteRecordIDs: deletedIDs)
                    if serverToken != nil {
                        self.previousToken = serverToken
                    }
                    self.saveBackingContext()
                }
                
                self.notifySyncEnd(err)
            }
            operation.savePolicy = .IfServerRecordUnchanged
            self.executeOperation(operation)
        }
    }
    
    private func fetchServerChanges(previousToken: CKServerChangeToken!, completionHandler: ([CKRecord], [CKRecordID], CKServerChangeToken!) -> Void) {
        var changed = [CKRecord]()
        var deleted = [CKRecordID]()

        let ope = CKFetchRecordChangesOperation(recordZoneID: zoneID, previousServerChangeToken: previousToken)
        ope.recordChangedBlock = { changed.append($0) }
        ope.recordWithIDWasDeletedBlock = { deleted.append($0) }
        ope.fetchRecordChangesCompletionBlock = { token, data, err in
            self.info("Server change: \( changed.count ) changed, \( deleted.count ) deleted \( err )")
            completionHandler(changed, deleted, token)
        }
        executeOperation(ope)
    }
    
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
}

// MARK: - Local Cache
extension JLCloudKitSync {

    // Map local objects to sync items
    private func addLocalObjectsToSyncQueue<T: SequenceType where T.Generator.Element: NSManagedObject>(set: T?, status: JLCloudKitItemStatus) -> Int {
        guard let objects = set else { return 0 }

        objects.forEach { obj in
            let item = self.fetchSyncItem(obj.objectID) ?? JLCloudKitItem(managedObjectContext: self.backingContext)
            self.updateSyncItem(item, object: obj, status: status)
        }
        return objects.underestimateCount()
    }
    
    private func removeLocalObject(recordIDs: [String]) {
        self.fetchLocalObjects(recordIDs).values.forEach { self.context.deleteObject($0) }
    }

    // Map a single local object to record
    private func updateRecordWithLocalObject(record: CKRecord, object: NSManagedObject) {
        object.entity.attributesByName.keys.forEach { k in
            record.setValue(object.valueForKey(k), forKey: k)
        }
        for (name, rel) in object.entity.relationshipsByName where !rel.toMany {
            if let relObj = object.valueForKey(name) as? NSManagedObject,
                recordName = self.fetchRecordName(relObj.objectID) {
                    let recordID = CKRecordID(recordName: recordName, zoneID: self.zoneID)
                    let ref = CKReference(recordID: recordID, action: CKReferenceAction.DeleteSelf)
                    record.setObject(ref, forKey: name)
            } else {
                warn("Can not find \( name ) for \( object )")
            }
        }
    }
    
    // Create a new record and set values from a local object
    private func recordWithLocalObject(recordName: String, object: NSManagedObject) -> CKRecord {
        let id = CKRecordID(recordName: recordName, zoneID: self.zoneID)
        let record = CKRecord(recordType: object.entity.name!, recordID: id)
        updateRecordWithLocalObject(record, object: object)
        return record
    }
    
    // Map all local objects to records, modified on exist ones, or newly created if necessary
    private func fetchOrCreateRecords(syncItems: [JLCloudKitItem], completionBlock: ([CKRecord]) -> Void) {
        var syncItemMappings = syncItems.reduce([String:JLCloudKitItem]()) { (var map, item) in
            map[item.recordID!] = item
            return map
        }
        
        let recordIDs = syncItems.map { $0.recordID! }
        var objects = fetchLocalObjects(recordIDs)
        var records: [CKRecord] = [ ]
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs.map { CKRecordID(recordName: $0, zoneID: self.zoneID) })
        operation.fetchRecordsCompletionBlock = { p, err in
            guard let results = p else { return }
            
            for (recordID, record) in results {
                let item = syncItemMappings[recordID.recordName]!
                let object = objects.removeValueForKey(recordID.recordName)!
                if item.lastModified! > record.modificationDate! {
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
        executeOperation(operation)
    }
    
    // Get record name by local object id
    private func fetchRecordName(managedObjectID: NSManagedObjectID) -> String? {
        return fetchSyncItem(managedObjectID)?.recordID
    }
    
    // MARK: Local Objects to Sync Item
    private func addAllLocalDataToSyncQueue() {
        var count = 0
        for e in context.persistentStoreCoordinator!.managedObjectModel.entities {
            let req = NSFetchRequest(entityName: e.name!)
            req.predicate = NSPredicate(value: true)
            let results = (try? context.executeFetchRequest(req)) as? [NSManagedObject]
            count += addLocalObjectsToSyncQueue(results, status: .Dirty)
        }
        info("\( count ) items added to sync queue")
    }
    
    // MARK: CKRecord to Local Objects
    
    // Map a single record to local object
    private func updateLocalObjectWithRecord(object: NSManagedObject, record: CKRecord) -> Bool {
        var clean = true
        
        object.entity.attributesByName.keys.forEach { k in
            object.setValue(record.valueForKey(k), forKey: k)
        }
        for (name, rel) in object.entity.relationshipsByName where !rel.toMany {
            if let refObj = record.valueForKey(name) as? CKReference {
                let relatedObjects = fetchLocalObjects([ refObj.recordID.recordName ])
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
        
        return clean
    }
    
    private func fetchLocalObjects(recordIDs: [String]) -> [String : NSManagedObject] {
        let req = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        req.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.recordID.rawValue ) IN %@", recordIDs)
        guard let results = try? self.backingContext.executeFetchRequest(req) else { return [ : ] }
        
        var objects = [String : NSManagedObject]()
        for item in results as! [JLCloudKitItem] {
            if let
                objectID = context.persistentStoreCoordinator!.managedObjectIDForURIRepresentation(NSURL(string: item.localObjectID! as String)!),
                object = try? context.existingObjectWithID(objectID) {
                    objects[item.recordID!] = object
            } else {
                warn("object no exists any more \( item.recordID! )")
            }
        }
        return objects
    }
    
    // MARK: CKRecord to Sync Items
    
    private func fetchSyncItems<T: SequenceType where T.Generator.Element: CKRecordID>(recordIDs: T) -> [JLCloudKitItem] {
        let recordNames = recordIDs.map { $0.recordName }
        let request = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        request.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.recordID.rawValue ) IN %@", recordNames)
        return (try? backingContext.executeFetchRequest(request) ?? [ ]) as! [JLCloudKitItem]
    }
    
    // MARK: Local Object to Sync Item
    
    private func fetchSyncItem(managedObjectID: NSManagedObjectID) -> JLCloudKitItem? {
        let request = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        request.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.localObjectID.rawValue ) = %@", managedObjectID.URIRepresentation())
        if let
            results = try? backingContext.executeFetchRequest(request),
            item = results.first as? JLCloudKitItem {
                return item
        }
        return nil
    }
    
    private func updateSyncItem(item: JLCloudKitItem, object: NSManagedObject, status: JLCloudKitItemStatus, date: NSDate = NSDate(), recordName: String? = nil) {
        if item.valueForKey(JLCloudKitItemAttribute.recordID.rawValue) == nil {
            let value = recordName ?? NSUUID().UUIDString
            item.setValue(value, forKey: JLCloudKitItemAttribute.recordID.rawValue)
        }
        item.setValue(object.objectID.URIRepresentation().absoluteString, forKey: JLCloudKitItemAttribute.localObjectID.rawValue)
        item.setValue(object.entity.name, forKey: JLCloudKitItemAttribute.type.rawValue)
        item.setValue(NSDate(), forKey: JLCloudKitItemAttribute.lastModified.rawValue)
        item.setValue(NSNumber(integer: status.rawValue), forKey: JLCloudKitItemAttribute.status.rawValue)
    }
}

// MARK: - Setup
extension JLCloudKitSync {
    
    private func setupContextStack(context: NSManagedObjectContext) {
        let model = generateModel()
        let persistentCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        do {
            try persistentCoordinator.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: storeURL, options: nil)
            
            backingContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
            backingContext.persistentStoreCoordinator = persistentCoordinator
            info("Store added to \(storeURL)")
        } catch {
            err("Failedto add store \(storeURL) since \(error)")
        }
    }
    
    private func generateModel() -> NSManagedObjectModel {
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
}

// MARK: - Utilities
extension JLCloudKitSync {
    
    private func saveBackingContext() {
        saveContext(backingContext, name: "Backing")
    }
    
    private func saveContext(context: NSManagedObjectContext, name: String) {
        context.performBlockAndWait {
            guard context.hasChanges else { return }
            do {
                try context.save()
                self.info("\(name) context saved")
            } catch  {
                self.info("Failed to save \(name) context. \(error)")
            }
        }
    }
    
    func clearSyncQueue() {
        clearData(backingContext, entityName: JLCloudKitItem.entityName())
    }
    
    private func clearDataInCloudKit(completionHandler: (NSError?) -> Void) {
        let db = CKContainer.defaultContainer().privateCloudDatabase
        db.deleteRecordZoneWithID(self.zoneID) { zoneID, error in
            self.info("Zone \( self.zoneName! ) cleared result \( error )")
            self.setupWorkZone( self.zoneName!, completionHandler: completionHandler)
        }
    }
    
    private func clearDataInLocalContext() {
        context.persistentStoreCoordinator!.managedObjectModel.entities.forEach { e in
            clearData(context, entityName: e.name!)
        }
    }
    
    private func clearData(context: NSManagedObjectContext, entityName: String) {
        let req = NSFetchRequest(entityName: entityName)
        _ = try? context.executeFetchRequest(req).forEach { context.deleteObject($0 as! NSManagedObject) }
    }
    
    private func removeFromSyncQueue(recordIDs: [String]) {
        let req = NSFetchRequest(entityName: JLCloudKitItem.entityName())
        req.predicate = NSPredicate(format: "\( JLCloudKitItemAttribute.recordID.rawValue ) IN %@", recordIDs)
        _ = try? backingContext.executeFetchRequest(req).forEach { backingContext.deleteObject($0 as! NSManagedObject) }
    }
    
    private func markSyncQueueClean(records: [CKRecord]) {
        let items = fetchSyncItems(records.map { $0.recordID })
        let recordMappings:[CKRecordID:CKRecord] = records.reduce([:]) { (var map, record) in
            map[record.recordID] = record
            return map
        }
        items.forEach { item in
            let recordID = CKRecordID(recordName: item.recordID!, zoneID: zoneID)
            let record = recordMappings[recordID]!
            item.lastModified = record.modificationDate
            item.status = NSNumber(integer: JLCloudKitItemStatus.Clean.rawValue)
        }
    }
    
    private func notifySyncBegin() {
        AsyncOnMainQueue {
            NSNotificationCenter.defaultCenter().postNotificationName(JLCloudKitSyncWillBeginNotification, object: nil)
        }
    }
    
    private func notifySyncEnd(error: NSError?) {
        AsyncOnMainQueue {
            var info: [NSObject: AnyObject] = [ : ]
            if error != nil { info["error"] = error }
            NSNotificationCenter.defaultCenter().postNotificationName(JLCloudKitSyncDidEndNotification, object: nil, userInfo: info)
        }
    }
    
    private func executeOperation(operation: CKDatabaseOperation) {
        CKContainer.defaultContainer().privateCloudDatabase.addOperation(operation)
    }
}