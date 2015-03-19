# JLCloudKitSync
Sync CoreData with CloudKit

__A dirty implementation to sync core data with CloudKit. Still under heavy development.__

## API

Setup

```swift
let syncer = JLCloudKitSync(context: context)
syncer.setupWorkZone("Your Zone Name Here", completionHandler: { error -> Void in
  // All things start from here
})
```

Discovery

```swift
syncer.discoverEntities(recordType: String) { (exists, error) -> Void in
	if exists {
		// There is already data in the cloud
	} else {
		// A fresh start!
	}
}
```

First Time Sync

```swift
// Data in the cloud will be replace with local one
syncer.performFullSync(JLCloudKitFullSyncPolicy.ReplaceDataOnCloudKit)
	
// Or, replace the local data with ones in cloud
syncer.performFullSync(JLCloudKitFullSyncPolicy.ReplaceDataOnLocal)
```

Normal Sync

```swift
// Sync will be automatically triggered after context is saved.
// Or you can perform a sync in any time by performSync()
syncer.performSync()
```
	
Notifications

```swift
// Sync starts with a begin notification
public let JLCloudKitSyncWillBeginNotification = "JLCloudKitSyncWillBeginNotification"
// and ends with a end notification
public let JLCloudKitSyncDidEndNotification = "JLCloudKitSyncDidEndNotification"
```
	
