---
title: "Welcome!"
---

* Table of Contents
{:toc}

# API summary

## EASY API

```luau
.EasyStoreCreate(DataStore, CreateSaveDataFunction): EasyStore

type EasyStore
EasyStore:StartSession(DataStoreKey): EasyProfile
EasyStore:StartSessionReusable(DataStoreKey): EasyProfile
EasyStore:SendRemoteChanges(DataStoreKey, RemoteChanges)

type EasyProfile
EasyProfile.IsActive: boolean
EasyProfile.IsLoaded: boolean

EasyProfile.ProductCreditChanged(ProductId, ChangeAmount): Signal
EasyProfile.Lifecycle(Status, Reason): Signal 
|-	EasyProfile.Destroyed(Reason): Signal
|-	EasyProfile.Saved(Reason): Signal
|-	EasyProfile.Replaced(Reason): Signal
	|-	EasyProfile.Loaded
	|-	EasyProfile.Reset(Reason): Signal
		|-	EasyProfile.Released: Signal
		|-	EasyProfile.Lost: Signal

EasyProfile:GetSaveData(): SaveData
EasyProfile:YieldUntilLoaded(): (ProfileIfLoaded: EasyProfile?)
EasyProfile:EndSession()

(wrappers of LockerState methods)
EasyProfile:MarkShouldSave()
EasyProfile:MarkForceSave()
EasyProfile:YieldUntilChangesSaved(): (WasSaved: boolean)
EasyProfile:WhenChangesSaved(Callback): SavedConnection
EasyProfile:ProductCreditQuery(ProductId): (Credit: number)
EasyProfile:ProductCreditGive(ProductId, Amount)
EasyProfile:ProductCreditUse(ProductId, Amount): (DidUse: boolean)

(wrappers of ProductPurchaser methods)
EasyProfile:CallWhenProductIsProcessedAndSaved(
	LockerState, ProcessFunction, ReceiptInfo, Callback)
EasyProfile:YieldUntilProductIsProcessedAndSaved(
	LockerState, ProcessFunction, ReceiptInfo): (WasSaved: boolean)
```

## HELPERS

```luau
.QueryConfig(Override, Default): Config

.TableDeepCopy(Table): Table
.TableRestoreBackup(Table, Backup)

.LogErrorVariations(Identifier, ErrorMessage)
.LogPrefixCreate(): string

type RequestErrorKind
.GetRequestErrorKind(PcallMessage): RequestErrorKind
```

## LOCKER SPEC
Configuration table needed by LockerStates & RemoteChangeSenders.

```luau
type LockerSpec 

type SaveData -- (extend from this when creating your own save data type)
type SaveDataMigrator
type SaveDataPatcher
```

### Global default callbacks & configs
These may also be defined in LockerSpecs, and the ones in LockerSpecs will
override these global ones.

```
.Default_LockerSpec_ReportDataStoreError()
.Default_RemoteChangeSender_ReportDataStoreError()

.Default_VerboseLogs
.Default_ReadOnlyDataStores
.Default_MaintainSessionPeriod
.Default_SessionExpiry
.Default_SessionRetryCooldown
.Default_PurchaseHistoryLimit
```

## LOCKER STATE
Active session locking & save data state associated with a UserId.

```luau
.LockerCreate(): LockerState
.LockerCreatePlayer(): LockerState

type LockerState
LockerState.SaveData: SaveData

type LoadStatus
LockerState.LoadStatus: LoadStatus

LockerState:MarkShouldAcquire()
LockerState:MarkShouldRelease()
LockerState:MarkShouldSave()
LockerState:MarkForceSave()
LockerState:SessionUpdate(HeartbeatNow): (ShouldRemove: boolean)

LockerState:ProductCreditQuery(ProductId): (Credit: number)
LockerState:ProductCreditGive(ProductId, Amount)
LockerState:ProductCreditUse(ProductId, Amount): (DidUse: boolean)

LockerState:YieldUntilChangesSaved(): (WasSaved: boolean)
LockerState:WhenChangesSaved(Callback): SavedConnection

type SavedConnection -- (used to detect when save data gets saved or reset)
SavedConnection.Saved: boolean
SavedConnection.Connected: boolean

SavedConnection:Trigger(WasSaved)
SavedConnection:Destroy()/Disconnect()
```

## PRODUCT PURCHASER
Robust developer product handling on LockerStates.

```luau
.ProductPurchaserCreate(): ProductPurchaser

type ProductOp
type ProductProcessFunction
type ReceiptInfo

type ProductPurchaser
ProductPurchaser:CallWhenProductIsProcessedAndSaved(
	LockerState, ProcessFunction, ReceiptInfo, Callback)
ProductPurchaser:YieldUntilProductIsProcessedAndSaved(
	LockerState, ProcessFunction, ReceiptInfo): (WasSaved: boolean)
ProductPurchaser:Update()
ProductPurchaser:Destroy()
```

## REMOTE CHANGE SENDER
Sending remote changes to data store keys that the server has not acquired a
session for.

```luau
.RemoteChangeSenderCreate(LockerSpec): RemoteChangeSender

type RemoteChangeSender
RemoteChangeSender:Destroy()
RemoteChangeSender:Update()
RemoteChangeSender:IsSending()
RemoteChangeSender:Send(DataStoreKey, RemoteChanges)

type SD_RemoteChange_Base -- (used when creating remote changes)
```

## MIGRATOR BUILDER

```
.MigratorBuilderCreate(): MigratorBuilder

type MigratorBuilder
MigratorBuilder:AddMigratorFrom(FromVersion, Migrator)
MigratorBuilder:AddPatcherFor(ForVersion, Patcher)
MigratorBuilder:CheckVersion(CurrentVersion)
MigratorBuilder:Build(): (Migrators, Patchers)
```
