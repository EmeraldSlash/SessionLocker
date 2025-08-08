--!strict

-- SessionLocker: DataStore session locking & save data management.
--
-- https://github.com/EmeraldSlash/SessionLocker
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 5 (2025-08-08)
--
-- Change Log:
--
-- Version 1: Initial version.
--
-- Version 2:
--
-- >> (See @DisableAPIs) After the SaveData table has been created for the first
-- time, it will never be replaced if DisableAPIs is enabled. Useful when 
-- usage code wants permanently customize save data for fake players or testing 
-- purposes or whatever.
--
-- Version 3:
--
-- >> Added .LogErrorVariations() which can be used to log variations of an 
-- error message so that the error will be aggregated in the experience's Error 
-- Report and then more specific variations can be specifically searched for.
--
-- >> Added .GsubFilter() which can be used to filter out specific information 
-- from logs, so that they get aggregated in the experience's Error Report.
--
-- >> Added .TableRestoreBackup() which can be used to restore a table to an older
-- version of itself (that was previously deep copied using .TableDeepCopy).
--
-- >> Added .QueryConfig() function for querying the value of a LockerSpec 
-- config value in the same way that the module does it.
--
-- >> Added .GetRequestErrorKind() function and .RequestErrorKind enum, used
-- for making decisions based on DataStore request errors.
--
-- Version 4: (Breaking changes!)
--
-- >> Reworked the easy API so that it works more like other session locking 
-- libraries, and so that it now supports session reuse and save data versions 
-- and migration.
--
-- >> Added MigratorBuilder which makes the process of creating migrators and
-- patchers a bit more user friendly.
--
-- Version 5: (Breaking changes!)
--
-- >> Made method calls the preferred way of calling functions because they have
-- better UX. All methods are still available as normal functions as well, 
-- prefixed by the acronym of the type name, for those who prefer that style.
--
-- >> Added LockerState:WhenChangesSaved() and LockerState:YieldUntilSaved(), a 
-- proper robust API for tracking save data changes. Use of ChangeIds is no 
-- longer recommended.
--
-- >> Added LockerSpec.Lifecycle() callback, replacing other LockerSpec 
-- callbacks related to save data. This makes the API much simpler and better 
-- communicates how save data changes over time.
--
-- >> Changed LoadStatus and ProductOp (previously named ProductProcessOp) enums
-- to unions of string singletons instead of being numbers. 
--
-- >> Fixed bug where yielded product processing threads would never be resumed
-- even when the LockerState is cleaned up.
--
-- >> Added .RemoteChangeSenderCreate() and RemoteChangeSender type, and a 
-- LockerSpec.ProcessRemoteChange() callback. Remote Changes are now supported!
--
-- >> Added .ProductPurchaseCreate() and ProductPurchaser to handle product 
-- processing in a way that is entirely separate from LockerStates. Product 
-- stuff is now entirely optional.
--
-- >> Improved the name of MigratorBuilder methods/functions.
--
-- >> EasyStore and EasyProfiles can now do everything that 
--
-- >> Lots of other small changes or renamed things.

local Module = {}

-- NOTE: This module is safe to be required on both server & client. You can 
-- require it on the client to get access to LoadStatus, SaveData or other thing
-- that you may want to replicate.

--
-- // API Summary
--
-------------------------------------------------------------------------------
-- EASY API
--
-- .EasyStoreCreate(DataStore, CreateSaveDataFunction): EasyStore
--
-- type EasyStore
-- EasyStore:StartSession(DataStoreKey): EasyProfile
-- EasyStore:StartSessionReusable(DataStoreKey): EasyProfile
-- EasyStore:SendRemoteChanges(DataStoreKey, RemoteChanges)
--
-- type EasyProfile
-- EasyProfile.IsActive: boolean
-- EasyProfile.IsLoaded: boolean
-- |
-- EasyProfile.ProductCreditChanged(ProductId, ChangeAmount): Signal
-- EasyProfile.Lifecycle(Status, Reason): Signal 
-- |-	EasyProfile.Destroyed(Reason): Signal
-- |-	EasyProfile.Saved(Reason): Signal
-- |-	EasyProfile.Replaced(Reason): Signal
-- 	|-	EasyProfile.Loaded
-- 	|-	EasyProfile.Reset(Reason): Signal
-- 		|-	EasyProfile.Released: Signal
-- 		|-	EasyProfile.Lost: Signal
-- |
-- EasyProfile:GetSaveData(): SaveData
-- EasyProfile:YieldUntilLoaded(): (ProfileIfLoaded: EasyProfile?)
-- EasyProfile:EndSession()
-- |
-- (wrappers of LockerState methods)
-- EasyProfile:MarkShouldSave()
-- EasyProfile:MarkForceSave()
-- EasyProfile:YieldUntilChangesSaved(): (WasSaved: boolean)
-- EasyProfile:WhenChangesSaved(Callback): SavedConnection
-- EasyProfile:ProductCreditQuery(ProductId): (Credit: number)
-- EasyProfile:ProductCreditGive(ProductId, Amount)
-- EasyProfile:ProductCreditUse(ProductId, Amount): (DidUse: boolean)
-- |
--	(wrappers of ProductPurchaser methods)
-- EasyProfile:CallWhenProductIsProcessedAndSaved(
--		LockerState, ProcessFunction, ReceiptInfo, Callback)
-- EasyProfile:YieldUntilProductIsProcessedAndSaved(
--		LockerState, ProcessFunction, ReceiptInfo): (WasSaved: boolean)
--
-------------------------------------------------------------------------------
-- HELPERS
--
-- .QueryConfig(Override, Default): Config
--
-- .TableDeepCopy(Table): Table
-- .TableRestoreBackup(Table, Backup)
--
-- .LogErrorVariations(Identifier, ErrorMessage)
-- .LogPrefixCreate(): string
--
-- type RequestErrorKind
-- .GetRequestErrorKind(PcallMessage): RequestErrorKind
--
-------------------------------------------------------------------------------
-- LOCKER SPEC:
-- (configuration table needed by LockerStates & RemoteChangeSenders)
--
-- type LockerSpec 
--
-- type SaveData (extend from this when creating your own save data type)
-- type SaveDataMigrator
-- type SaveDataPatcher
---
-- Global default callbacks & configs:
--
-- (These may also be defined in LockerSpecs, and the ones in LockerSpecs will
-- override these global ones.)
--
-- .Default_LockerSpec_ReportDataStoreError()
-- .Default_RemoteChangeSender_ReportDataStoreError()
--
-- .Default_VerboseLogs
-- .Default_ReadOnlyDataStores
-- .Default_MaintainSessionPeriod
-- .Default_SessionExpiry
-- .Default_SessionRetryCooldown
-- .Default_PurchaseHistoryLimit
--
-------------------------------------------------------------------------------
-- LOCKER STATE
-- (active session locking & save data state associated with a UserId)
--
-- .LockerCreate(): LockerState
-- .LockerCreatePlayer(): LockerState
--
-- type LockerState
-- LockerState.SaveData: SaveData
-- |
-- type LoadStatus
-- LockerState.LoadStatus: LoadStatus
-- |
-- LockerState:MarkShouldAcquire()
-- LockerState:MarkShouldRelease()
-- LockerState:MarkShouldSave()
-- LockerState:MarkForceSave()
-- LockerState:SessionUpdate(HeartbeatNow): (ShouldRemove: boolean)
-- |
-- LockerState:ProductCreditQuery(ProductId): (Credit: number)
-- LockerState:ProductCreditGive(ProductId, Amount)
-- LockerState:ProductCreditUse(ProductId, Amount): (DidUse: boolean)
-- |
-- LockerState:YieldUntilChangesSaved(): (WasSaved: boolean)
-- LockerState:WhenChangesSaved(Callback): SavedConnection
--
-- type SavedConnection (used to detect when save data gets saved or reset)
-- SavedConnection.Saved: boolean
-- SavedConnection.Connected: boolean
-- |
-- SavedConnection:Trigger(WasSaved)
-- SavedConnection:Destroy()/Disconnect()
--
-------------------------------------------------------------------------------
-- PRODUCT PURCHASER
-- (robust developer product handling on LockerStates)
--
-- .ProductPurchaserCreate(): ProductPurchaser
-- 
-- type ProductOp
-- type ProductProcessFunction
-- type ReceiptInfo
--
-- type ProductPurchaser
-- ProductPurchaser:CallWhenProductIsProcessedAndSaved(
-- 	LockerState, ProcessFunction, ReceiptInfo, Callback)
-- ProductPurchaser:YieldUntilProductIsProcessedAndSaved(
-- 	LockerState, ProcessFunction, ReceiptInfo): (WasSaved: boolean)
-- ProductPurchaser:Update()
-- ProductPurchaser:Destroy()
--
-------------------------------------------------------------------------------
-- REMOTE CHANGE SENDER
-- (sending remote changes to data store keys that the server has not acquired a
-- session for)
--
-- .RemoteChangeSenderCreate(LockerSpec): RemoteChangeSender
--
-- type RemoteChangeSender
-- RemoteChangeSender:Destroy()
-- RemoteChangeSender:Update()
-- RemoteChangeSender:IsSending()
-- RemoteChangeSender:Send(DataStoreKey, RemoteChanges)
-- |
-- type SD_RemoteChange_Base (used when creating remote changes)
--
-------------------------------------------------------------------------------
-- MIGRATOR BUILDER
--
--	.MigratorBuilderCreate(): MigratorBuilder
--
-- type MigratorBuilder
-- MigratorBuilder:AddMigratorFrom(FromVersion, Migrator)
-- MigratorBuilder:AddPatcherFor(ForVersion, Patcher)
-- MigratorBuilder:CheckVersion(CurrentVersion)
-- MigratorBuilder:Build(): (Migrators, Patchers)

--
-- // Defining LockerSpec
--

-- LockerSpec is the big structure you must pass in when wanting to start doing 
-- session locking for a particular UserId. It contains all the information 
-- needed by the module, as well as additional configurations. You can have as 
-- many LockerSpecs as you want, so you aren't locked in to using a single 
-- DataStore or kind of data.

export type LockerSpec = {
	--
	-- Required parameters
	--
	
	DataStore: DataStore;
	
	-- SaveDataVersion must start at 1, and increment by 1 with every version 
	-- change, because it is used as an index into the SaveDataMigrators array.
	--
	-- This field will place a hard limit on whether a player's save data can be 
	-- used or not. If a player joins a server with a version that the server 
	-- doesn't know about then the player will be put into the safe mode where no 
	-- data can be loaded or saved at all. (In this scenario the module stores and 
	-- exposes what version was loaded, so that you can use that information to 
	-- respond appropriately e.g. find new servers which are >= that version to 
	-- teleport players to.)
	SaveDataVersion: number;
	
	-- Migrators.
	SaveDataMigrators: {[number]: SaveDataMigrator}; -- [FromVersion]: MigratorToNextVersion
	SaveDataPatchers: {[number]: SaveDataPatcher}; -- [CurrentVersion]: PatcherCurrentVersion
	
	-- Creates new save data of the latest SaveDataVersion when needed. Must not 
	-- yield, as it can be called from within UpdateAsync transform functions.
	SaveDataCreator: (()->(SaveData));
	
	--
	-- Optional functions
	--
	-- If an optional function is not provided, some functions have a default 
	-- version Module.Default_* which you can have a look at. Also see 
	-- @CallbackCallingConvention and @CallbackTableMutation
	
	-- This function will be called whenever data is loaded, saved, or replaced. 
	-- It will also provide a reason for what happened, if applicable. See
	-- @Lifecycle for more info.
	Lifecycle: ((LS: LockerState, Status: LifecycleStatus, Reason: LifecycleReason)->())?;
	
	-- Use this to detect when the state of a session changes. Which is quite 
	-- important for understanding how to interpret and interact with 
	-- LockerState.SaveData, and so on.
	LoadStatusChanged: ((LS: LockerState)->())?;
	
	-- If set, this function will be called when save data is loaded, and the 
	-- default local "offline" copy of save data (SourceSD) is about to be 
	-- replacted by the newly loaded save data (DestSD).
	--
	-- The function should merge applicable data from SourceSD into DestSD, 
	-- mutating DestSD.
	--
	-- SourceSD is guaranteed to never have been saved before, it's completely 
	-- fresh dummy data that the player was using before the real data loaded. 
	--
	-- Note that only some values may be mergable: for example, if you track a 
	-- player's playtime, you could do DestSD.TimePlayedSeconds += 
	-- SourceSD.TimePlayerSeconds, but if for some reason you give each save data
	-- a unique GUID then it would not make sense to do DestSD.GUID = 
	-- SourceSD.GUID.
	MergeOfflineSaveDataWithLoadedSaveData: ((
		LS: LockerState,
		SourceSD: any,
		DestSD: any
	)->())?;
	
	-- This function will be called to apply a RemoteChange to SaveData (mutating
	-- SaveData). It should return true if the RemoteChange should be deleted 
	-- now (it was applied successfuly), or false if the RemoteChange needs to be
	-- kept around (RemoteChange.K was an unknown value, or there was a 
	-- temporary error in applying the change). This code should be extremely
	-- conservative and safe so that it doesn't throw errors.
	ProcessRemoteChange: ((
		SD: any,
		RemoteChange: any
	)->(boolean))?;
	
	-- This function will be used to report common boring errors that are 
	-- specifically related to backend or network communication failures, and are
	-- generally not relevant for our own code.
	--
	-- In addition to the arguments provided, other relevant fields can be
	-- retrieved from the LockerState argument, most notably:
	--
	-- .DataStore
	-- .DataStoreKey
	-- .AssociatedUserIds
	-- .LogPrefix
	--
	ReportDataStoreError: ((
		LS: LockerState,
		OperationName: string,
		ErrorMessage: string
	)->())?;
	
	-- This function will be called when SaveData.ProductCredit is modified by
	-- LS:ProductCreditGive() or LS:ProductCreditUse().
	ProductCreditChanged: ((
		LS: LockerState,
		SD: any,
		ProductId: number,
		ChangeAmount: number,
		UserData: any
	)->())?;
	
	--
	-- Optional configuration values
	--
	-- If a value is nil, then the corresponding Module.Default_* value will be 
	-- used instead. You can use .QueryConfig() function to query these
	-- the same way that the module checks them.
	
	VerboseLogs: boolean?;
	
	-- If set to true, DataStores will be read from but never modified. Session 
	-- locks pretend to be obtained, but they haven't actually been obtained. 
	ReadOnlyDataStores: boolean?;
	
	-- Maximum duration save data is allowed to go without saving to maintain the
	-- server's session lock.
	MaintainSessionPeriod: number?;
	
	-- Other servers will be able to claim the session if the session lock is not 
	-- updated for this period of time.
	SessionExpiry: number?;
	
	-- How long to wait between failed header requests.
	SessionRetryCooldown: number?;
	
	-- How many entries can be stored in product purchase history before old 
	-- purchases are forgotten. Avoid changing this unnecessarily as it will 
	-- affect save data. 
	PurchaseHistoryLimit: number?;
}

-- Function used for checking if a LockerSpec's configuration value is set.
function Module.QueryConfig<T>(Override: T?, Default: T): T
	return if Override ~= nil then Override else Default
end

--
-- @Lifecycle
--

export type LifecycleStatus =
	-- Indicates LockerState.SaveData has been replaced with a new table for some
	-- reason (see LifeCycle reason for ways this may happen). Beware that all 
	-- ChangeIds will be reset when this happens.
	| "replaced"

	-- Indicates that SaveData was saved successfully.
	| "saved"

	-- Indicates the the LockerState was removed and is no longer usable. This 
	-- will always be called after session has been reset, meanining "replaced" 
	-- status will always be seen first. So you should never need to clean up 
	-- state in response to a "destroyed" if that state is already being cleaned 
	-- up by the code that handles a "replaced".
	| "destroyed"

export type LifecycleReason =
	-- status = "saved"
	-- status = "destroyed"
	| "none"
	
	-- status = "replaced":
	-- Indicates that save data was replaced with newly loaded save 
	-- data.
	| "r_loaded"

	-- status = "replaced":
	-- Indicates that the session was released willingly, so save data 
	-- was replaced with default template save data. The lock may be reaquired
	-- automatically in the future. This reason will occur when the save data is
	-- first created, as the release state is intentional here.
	| "r_released"

	-- status = "replaced":
	-- Indicates that the session lock was lost unwillingly (another server 
	-- probably stole the session lock). The lock may be reacquired automatically
	-- in the future.
	--
	-- This scenario should be extremely rare, however there are two ways it 
	-- could happen:
	--
	-- 1) If the current server repeatedly fails to maintain the session lock for
	-- 30 minutes straight, for example due to DataStore budgets or Roblox 
	-- backend issues, and then another server attempts to take the session lock,
	-- that other server will be able to take it. (The 30 minutes here comes 
	-- from the default LockerSpec.SessionExpiry setting.)
	--
	-- 2) If the servers' timestamps are out of sync then another server will be 
	-- able to take the session lock if it is 30 minutes ahead of the current 
	-- server. (Or less, if that current server is also in situation #1 where it 
	-- is struggling to maintain the session lock.) You need to be careful with 
	-- the settings as you will have frequent session lock stealing if 
	-- (LockerSpec.SessionExpiry - math.abs(TimestampDifference)) <= 
	-- LockerSpec.MaintainSessionPeriod.
	--
	| "r_lost" 

--
-- // Callback details
--
-- There are two important details about how LockerSpec callbacks are handled.
--
-- 1. @CallbackCallingConvention
--
-- To avoid unnecessary proliferation of units of code execution, all callbacks 
-- will be called directly i.e. without task.spawn(), pcall(), or any other 
-- wrappers.
--
-- This means you MUST avoid yielding or throwing errors in ALL callbacks, as it
-- will break the module's code. If you need to yield, you should put a 
-- task.spawn() inside your callback, or find some other means to perform work 
-- asynchronously. If you feel about unsure errors, just wrap the body of your 
-- callbacks in a pcall.
--
-- Wrapper code for code execution is trivial, or in the case where it isn't, 
-- it's highly specific to your game and code architecture, so generally the 
-- module does not provide any out of-the-box. You can create those yourself to 
-- suit your own needs.
--
-- 2. @CallbackTableMutation
--
-- Secondly, to avoid lots of unnecessary memory copying and weird table 
-- identification issues, tables are always passed directly into callbacks
-- without modification.
--
-- If a callback is expected to modify or perform some operation on a table (in 
-- the case of this module, it's usually a SaveData table), the callback is 
-- expected to mutate the input table (and does not need to return it), rather 
-- than return a new table.

--
-- // Logging details
--
-- You may want to log things in different ways, so generally the module tries 
-- to give you as much control over logging as possible. DataStore errors are 
-- logged via the LockerSpec.ReportDataStore callback.
--
-- The module also has some internal vorbose logging which can be enabled for 
-- debugging/testing purposes. Its use is largely intended to be for myself.

--
-- // Typechecking
--
-- In your codebase it is recommended to have a canonical "save data" type,
-- which extends the .SaveData type, e.g.
--[[

type MySaveData = SessionLocker.SaveData & { ... }

--]]
-- To avoid lots of type checking complexity and annoying boilerplate, I have 
-- decided it is best to avoid having the module track your canonical save data 
-- type. Instead, whenever your code recieves a "SaveData" type, it will be of 
-- type any, and you will have to manually convert it to your own type every 
-- time you want to use it. To conveniently access save data in your canonical
-- type, I recommend defining a function such as:
--[[

local function ToMySaveData(SD: any) return SD :: MySaveData end
local function GetMySaveData(LS: SessionLocker.LockerState) return LS.SaveData :: MySaveData end
	
--]]
-- You can also define a LockerSpec.SaveDataReplaced function, which will be 
-- called whenever LockerState.SaveData gets replaced by a new table. This can
-- store a correctly typed field somewhere, like:
--[[

LockerSpec.SaveDataReplaced = function(LS) MySaveData[LS.UserId] = LS end
	
--]]
-- Note that to clean this up you should clear any stored data when the 
-- LockerState itself gets cleaned up by your code after 
-- LockerState:SessionUpdate() indicates the LockerState should be removed.
--
-- Finally, I also recommend having a separate ModuleScript for storing 
-- historical save data types, migrators, and patchers, isolated from the your
-- codebase. e.g.
--[[

type MySaveData_V1 = {...}
type MySaveData_V2 = {...}
type MySaveData_V3 = {...}
type MySaveData_V4 = {...}

local Migrators = {}
local Patchers = {}

Migrators[1] = function(SD: MySaveData_V1) return 0 end
Migrators[2] = function(SD: MySaveData_V2) return 1 end
Patchers[3] = function(SD: MySaveData_v3, VersionPatch: number) return 1 end
Migrators[3] = function(SD: MySaveData_V3) return 0 end
Migrators[4] = function(SD: MySaveData_V4) return 0 end

return {
	Migrators = Migrators;
	Patchers = Patchers;
}
--]]

--
-- // Using save data
--
-- This module is effectively just an API for doing session locked DataStores. 
-- As such it provides no metatable magic, syntax sugar, client/server 
-- replication, changed signals, etc.
--
-- Reading and writing the save data is as easy as directly accessing the 
-- LockerState.SaveData table. If you want to have your own stuff wrapped around
-- it, you can just define your own getters/setters, and also a 
-- LockerSpec.SaveDataReplaced callback.

--
-- // Modifying save data structure
--
-- When you want to make a change to save data structure for a particular 
-- LockerSpec, you should:
--
-- 1) Increment LockerSpec.SaveDataVersion.
--
-- 2) Modify your canonical save data type however you like.
--
-- 3) Also put your canonical save data type into your migrator code, and
-- create a new migrator from the previous Version to the new Version.
--
-- If the changes you are making to the save data are 100% backwards compatible,
-- such as adding optional fields to the canonical SaveData type. In that case 
-- you should just go ahead with modifying the canonical save data type, apply 
-- those changes also to the duplicate type in the migrator code, then publish 
-- your game and call it a day. 

--
-- // Migrators and patches
--
-- @MigratorDocs
--
-- Migrators, Patchers, LockerSpec.SaveDataCreator(), and 
-- LockerSpec.MergeOfflineSaveDataWithLoadedSaveData() are the only mechanisms 
-- the module has for modifying save data tables. Except for the keys defined in
-- the .SaveData type (which are managed by the module), the module will never 
-- create, modify, or delete keys on its own.
--
-- Migrators and Patchers should always be stored in the array in terms of the 
-- LockerSpec.SaveDataVersion of the input. So if you have a migrator from 
-- version 5 to version 6, or a Patcher for version 5, then in both cases you 
-- should store the function at index 5 of the Migrators or Patchers table.
--
-- Because SaveDataVersions must be consecutive, and a Migrator must always be 
-- defined between versions, no holes are permitted in the Migrators array. On 
-- the other hand, Patchers are optional, so holes are permitted in the Patchers 
-- array.
--

--
-- // Migrators
--
-- It is required that you create a Migrator for every version change. A 
-- beneficial consequence of this is that you can define fields in SaveData that
-- are guaranteed to exist, because you can just get the migrator to create the
-- field. So this enables you to avoid having to check things like "if 
-- SaveData.Inventory then" if you can just guarantee that SaveData.Inventory is
-- always defined.
--
-- A Migrator function takes a table of SaveData from the previous 
-- version as input and mutates it so that the save data now has the next 
-- version. e.g. it takes SaveData from version 1 and mutates it to version 2.
--
-- Mutators generally should not modify any values defined in .SaveData. DO NOT 
-- modify the version and session values, because they will be modified 
-- appropriately outside of the migrator. It is fine for you to do things like 
-- like make changes to SaveData.PurchaseHistory or SaveData.ProductCredit.

-- It also should return the new VersionPatch of the save data. For a new 
-- migrator, I recommend just returning 0, then every time you modify the 
-- migrator function you should increment that value. This return value should 
-- always be the same as the corresponding Patcher's return value. See Patchers 
-- documentation below for further explanation.
--
-- After a Migrator is executed, the module will set SaveData.Version += 1.

export type SaveDataMigrator = (Data: any) -> (number)

-- Example Migrator
--[[

type SD_V1 = {
	OldValue: string;
}
type SD_V2 = {
	NewValue: boolean;
}

Migrators[1] = function(SD_V1: SaveData_V1)
	local SD_V2: SaveData_V2 = SD_V :: any

	-- Delete something from the old version.
	SD_V2.OldValue = nil :: any
	
	-- Add something to the new version.
	SD_V2.NewValue = true 
	
	-- Return a VersionPatch of 0.
	return 0
end

--]]

--
-- // Patchers
--
-- Each version can optionally have a Patcher function associated with it. The 
-- purpose of a Patcher is to fix any issues with SaveData caused by the 
-- previous Migrator (e.g. if there was a bug in the version 4->5 migrator, then
-- the patcher for version 5 can fix it) or caused by a buggy Patcher function.
--
-- If defined, it will be called every time the data loads, including before the
-- data is migrated for the first time. By this I mean that if you are 
-- migrating from version 2 -> 3 -> 4, and there are Patchers for versions 2, 3, 
-- and 4, then only the Patcher for Version 2 will be called, because all the 
-- subsequent migrators are guaranteed to be correct.
--
-- Patchers mutate the input SaveData similarly to migrators, and have the same 
-- restrictions on what fields you can modify.
--
-- Patchers have an additional argument, the value of SaveData.VersionPatch. 
-- (This saves you having to lookup it up in the table yourself and do all the 
-- type checking and stuff if you don't care about that.) This argument can be 
-- used to identify what "patch version" of the data the function is working 
-- with, so it knows if e.g. it is working with data that has already been fixed
-- so doesn't need to be changed, or if the data it is looking at is still 
-- broken and needs fixing.
--
-- The Patcher must also return the new VersionPatch value. (Again it should not 
-- set it directly on the SaveData, it should return it.) Then the module will
-- set SaveData.VersionPatch to that returned value.
--
-- There is no limitation on how you choose values for VersionPatch, aside from 
-- that it must be a number. However it is generally a good idea to start 
-- VersionPatch at 0 (have the original migrator function return 0), then 
-- increment it by 1 every time you change you something (modify the patcher
-- function / migrator function).
--
-- As mentioned earlier, the Migrator function must also return the VersionPatch
-- value. The Patcher and Migrator functions with the same Version as output 
-- should return the same VersionPatch value. e.g. the functions stored at 
-- Migrators[1] and Patchers[2] should be return the same VersionPatch. If you 
-- want, you can make a variable for each version's patch value, such as "local 
-- SaveData_V5_Patch = 2" and use that as the return value for all patchers. But
-- you don't have to.

export type SaveDataPatcher = (Data: any, VersionPatch: number) -> (number)

-- Example Patcher
--[[

Patchers[Version] = function(SD_V: SaveData_Version, VersionPatch: number)

	if VersionPatch == 0 then
		-- Restore some value that was incorrectly forgotten by the Migrator.
		local SD_Old: SD_OldVersion = SD_V
		SD_V.Value = SD_Old.Value
	end
	
	-- Return the new value we should use for VersionPatch.
	return 1
end

--]]

--
-- // What to do if you discover a problem in your migrator function:
--
-- 1) Edit the broken code as necessary to fix the problems e.g. if the problem 
-- was in the migrator function then you should fix the migrator function, or if
-- the problem was in the patcher then you should just fix the patcher.
--
-- 2) Create/modify a patcher function for the version of the migrator, to 
-- automatically fix problems introduced into the save data by the migrator or 
-- other issue (e.g. a bug in the patcher). Make sure to use the VersionPatch 
-- argument to check whether the data needs to be fixed or not.
--
-- 3) Choose a new "latest" VersionPatch value (e.g. increment from the previous
-- value), and make both the Patcher[N] and Migrator[N-1] functions return this
-- same value.
--

--
-- Utilities
--

-- Use this for easily creating new save data from a template table.
function Module.TableDeepCopy<T>(Table: T): T
	
	local Result = {
		Root = (nil :: any) :: T;
	}
	
	-- Duplicate references to the same table are handled correctly by caching 
	-- all the new tables we create. We don't handle table keys though. (Save 
	-- data should never have duplicate references in it though.)
	local TableCache: {[any]: any} = {}
	
	type Entry = {
		Source: {[any]: any};
		Parent: {[any]: any};
		Key: any;
	}
	local Stack: {Entry} = {{
		Source = Table :: any;
		Parent = Result :: any;
		Key = "Root";
	}}
	while true do
		local Entry = table.remove(Stack)
		if not Entry then
			break
		else
			
			local CachedTable = TableCache[Entry.Source]
			if CachedTable then
				Entry.Parent[Entry.Key] = CachedTable
			else
				
				local Clone = table.clone(Entry.Source)
				Entry.Parent[Entry.Key] = Clone
				for Key, Value in Clone do
					if type(Value) == "table" then
						Stack[#Stack+1] = {
							Source = Value;
							Parent = Clone;
							Key = Key;
						}
					end
				end
			end
		end
	end
	
	return Result.Root
end

-- Use this for restoring a table to an older backup of itself (created using 
-- .TableDeepCopy with the original table before making modifications to it).
function Module.TableRestoreBackup<A,B,C,D>(
	Table: {[A]: B},
	Backup: {[C]: D}
): {[C]: D}
	table.clear(Table)
	local _Table: {[C]: D} = Table :: any 
	for Key, Value in Backup do
		_Table[Key] = Value
	end
	return _Table
end

-- Logs variations of a task's error message. The variations will be 
-- with/without the traceback, and with/without the detailed error message.
--
-- This means that even if the error message or traceback contains highly 
-- specific, infrequent information (such as a specific player's UserId), the 
-- variations of the error without that information will still be aggregated by 
-- the experience's Error Report so you can easily find out that the error is 
-- happening. Once you know it is happening, you should be able to filter the 
-- Error Report using the Identifier argument you gave to the log.
--
function Module.LogErrorVariations(Identifier: string, ErrorMessage: string)
	local LogPlain = ("%s failed")
		:format(Identifier)
	local LogError = ("%s failed with error:\n%s")
		:format(Identifier, tostring(ErrorMessage))
	local Traceback = debug.traceback()
	
	warn(LogPlain)
	warn(LogPlain.."\n"..Traceback)
	warn(LogError)
	warn(LogError.."\n"..Traceback)
end

-- An alternative way to get your logs to be aggreggated by the Error Report 
-- aggregation is to filter out user IDs and other specific information from 
-- error messages using string.gsub().
--
-- This function achieves that using an array of filters, e.g. you might
-- use it like:
--[[
warn(SessionLocker.GsubFilter(Message, {
	{tostring(Player.UserId), "{userid}"};
	{Player.Name, "{username}"};
}))
--]]
function Module.GsubFilter(Message: string, Filters: {{string}})
	local Final = Message
	for _, Filter in Filters do
		if type(Filter[1]) == "string" and
			type(Filter[2]) == "string"
		then
			Final = Final:gsub(Filter[1], Filter[2])
		end
	end
	return Final
end

-- Make a nice log prefix which will be used in verbose logs and any code which
-- decides to use the LockerState.LogPrefix field.
function Module.LogPrefixCreate(
	ShowModule: boolean,
	
	RealUserId: number,
	
	-- If UserId used for DataStore is different from the player's actual UserId 
	-- then we will log both. (It is sometimes a useful thing for debugging 
	-- purposes to use another player's UserId.)
	DataStoreUserId: number?,
	
	-- If we want to show a player's name, or some other text beforehand, we can
	-- do that here.
	Name: string?
): string
	local Str = {}
	if ShowModule then
		Str[#Str+1] = "[SessionLocker]"
	end
	if Name then
		Str[#Str+1] = ("[%s]:"):format(Name)
	end
	if DataStoreUserId and DataStoreUserId ~= RealUserId then
		Str[#Str+1] = ("[%d / %d]"):format(RealUserId, DataStoreUserId)
	else
		Str[#Str+1] = ("[%d]"):format(RealUserId)
	end
	return table.concat(Str)
end

-- A way of categorizing DataStore request errors based on the message returned 
-- by pcall(). 
--
-- Based on the table of error codes from:
-- https://create.roblox.com/docs/cloud-services/datastores
--
-- (Note: The table has since been removed from that page, so I guess Roblox 
-- isn't committed to supporting these error codes.)
--
-- Lower values mean the issue is on our end, higher values mean issue is on 
-- Roblox's end.

export type RequestErrorKind =
	-- Errors relating to our code (shouldn't retry, should log).
	| "script"
	
	-- Errors that may be temporary or are unknown (should retry, but maybe not 
	-- indefinitely, and should log).
	| "misc"
	
	-- Errors relating to request limits or Roblox server issues (should retry 
	-- indefinitely, and shouldn't log).
	| "backend"

function Module.GetRequestErrorKind(PcallMessage: string): RequestErrorKind
	local Result: RequestErrorKind

	if PcallMessage then
		local ErrorCode = string.match(PcallMessage, "^(%d+):")
		if ErrorCode then
			local FirstChar = string.sub(ErrorCode, 1, 1)
			if FirstChar == "1" then
				Result = "script"
			elseif FirstChar == "3" then
				Result = "backend"
			elseif FirstChar == "4" then
				if ErrorCode == "404" then
					Result = "misc"
				else
					Result = "script"
				end
			elseif FirstChar == "5" then
				local Lookup: {[string]: RequestErrorKind} = {
					["501"] = "misc";
					["502"] = "backend";
					["503"] = "misc";
					["504"] = "misc";
					["505"] = "misc";
					["511"] = "script";
					["512"] = "script";
					["513"] = "script";
					["514"] = "script";
				}
				local Kind: RequestErrorKind = Lookup[ErrorCode]
				if Kind then
					Result = Kind
				end
			end
		end
	end

	if not Result then
		Result = "misc"
		-- Always warn when an unknown DataStore error is encountered.
		warn(debug.traceback(("Unknown DataStore error: \"%s\""):format(PcallMessage)))
	end

	return Result
end

--
-- Default options
--

Module.Default_VerboseLogs = false
Module.Default_ReadOnlyDataStores = false
Module.Default_MaintainSessionPeriod = 5*60
Module.Default_SessionExpiry = 30*60
Module.Default_SessionRetryCooldown = 10
Module.Default_PurchaseHistoryLimit = 100

Module.Default_LockerSpec_ReportDataStoreError = function(
	LS: LockerState,
	OperationName: string,
	ErrorMessage: string
)
	local Message = " ReportDataStoreError:\n"..tostring(ErrorMessage)
	
	-- If verbose logs are enabled, we give the error message with full details.
	local LSpec: LockerSpec = LS.LockerSpec
	if Module.QueryConfig(LSpec.VerboseLogs, Module.Default_VerboseLogs) then
		local LogPrefix: string = LS.LogPrefix
		warn(LS.LogPrefix..Message)
		
	-- Otherwise, we filter out all identifying information and just give the
	-- generic message, if it isn't a known backend error.
	elseif Module.GetRequestErrorKind(ErrorMessage) ~= "backend" then
		
		local Filters = {}
		for _, UserId in LS.AssociatedUserIds do
			Filters[#Filters+1] = {tostring(UserId), "{userid}"}
		end
		Filters[#Filters+1] = {LS.DataStoreKey, "{datastorekey}"}
		warn("[SessionLocker]"..Module.GsubFilter(Message, Filters))
	end
end

--
-- Types and stuff
--

export type SaveData = {
	-- These must not be modified within Migrators or by your own code!
	Version: number;
	VersionPatch: number;
	Session: SD_Session?;
	
	-- These may be modified within your Migrators, but should not be modified 
	-- directly by your own code.
	Purchases: {SD_Purchase}?; -- Used by ProductPurchaser.
	ProductCredit: {SD_ProductCredit}?; -- Used by ProductCredit operations.
	RemoteChanges: {SD_RemoteChange}?; -- Used by RemoteChange operations.
}

-- This type is what needs to be defined by your code that creates 
-- RemoteChanges, and to be read by your code that processes RemoteChanges!
export type SD_RemoteChange_Base = {
	
	-- Kind: Used to identify what operation this RemoteChange is doing. Defined 
	-- by the user.
	K: string;
	
}

-- You don't need to worry about these fields as they will be created & managed 
-- entirely by the module.
export type SD_RemoteChange_Internal = {
	
	-- Id: of the RemoteChange, used to disambiguate similar RemoteChanges.
	I: number;
	
	-- At: Timestamp when this RemoteChange was created. Currently unused, but
	-- may be useful in the future.
	A: number;
	
}
export type SD_RemoteChange = SD_RemoteChange_Base & SD_RemoteChange_Internal

-- {ProductID: number, PurchaseID: string, Timestamp: number}
export type SD_Purchase = {number|string}

-- {ProductId: number, Count: number}
export type SD_ProductCredit = {number}

type SD_Session = {
	PlaceId: number;
	JobId: string;
	LockId: number;
	UpdatedAt: number;
}
local SessionRNG = Random.new()
local function SessionCreate(): SD_Session
	return {
		PlaceId = game.PlaceId;
		JobId = game.JobId;
		LockId = SessionRNG:NextInteger(0, 2^32-1);
		UpdatedAt = os.time();
	}
end
local function SessionEqual(A: SD_Session, B: SD_Session): boolean
	return
		(A.PlaceId == B.PlaceId) and
		(A.JobId == B.JobId) and
		(A.LockId == B.LockId)
end
local function SessionExpired(A: SD_Session, LockerSpec: LockerSpec): boolean
	return (os.time() - A.UpdatedAt) > (LockerSpec.SessionExpiry or Module.Default_SessionExpiry)
end

export type SessionLoadState = {
	NextAttemptAt: number;
	Thread: thread?;
	Result: SLS_Result?;
}
export type SLS_Result = {
	LoadStatus: LoadStatus;
	SaveData: SaveData;
	MinimumServerVersion: number?;
}

export type SessionSaveState = {
	NextAttemptAt: number;
	ShouldReleaseSession: boolean;
	Thread: thread?;
	Result: SSS_Result?;
}
export type SSS_Result = {
	RequestSuccess: boolean;
	LostSessionLock: boolean;
	SessionReleased: boolean;
	SessionAt: number;
	ChangeId: number;
	ProcessedRemoteChanges: {[number]: boolean};
	ImportedRemoteChanges: {SD_RemoteChange}?;
}

export type SessionState = {
	Session: SD_Session;
	AutosaveAt: number;
	SessionSaveState: SessionSaveState?;
}

export type LoadStatus =
	-- Still waiting to obtain the session lock.
	| "loading"

	-- Couldn't perform the DataStore request to obtain session lock. Roblox's
	-- backend may be having issues.
	| "data_store_request_fail"

	-- The session lock is currently held by another server. Need to wait for
	-- it to release the lock, or for the lock to expire.
	| "session_is_locked"

	-- The SaveData.Version field isn't known by this server. The save data is 
	-- probably from a newer server (the game was recently updated most likely).
	| "invalid_version"

	-- SaveData has loaded and the session lock has been obtained.
	| "loaded"

export type LockerState = {
	
	--
	-- Independent of session locks
	--
	
	AssociatedUserIds: {number};
	DataStoreKey: string;
	LockerSpec: LockerSpec;
	LogPrefix: string;
	
	-- Used for disabling saving / loading. Useful if you have things like
	-- fake players or want to temporarily turn of DataStore requests.
	DisableAPIs: boolean?;
	
	InUse: {[any]: boolean};
	IsRemoved: boolean;
	
	-- Reset with each new session
	
	-- The save data is always present so that it can be used and modified even 
	-- while the real save data is loading or has failed to load. Upon a 
	-- successful load, any changes made to the offline save data body will be 
	-- merged into the newly loaded body.
	SaveData: SaveData;
	
	-- Anything that modifies the save data should increment ChangeId_Pending to 
	-- inform the library that a change needs to be saved. ChangeId_PendingForce 
	-- will force data to be saved immediately if it is higher than 
	-- ChangeId_Saved. ChangeId_Saved indicates the highest ChangeId which has 
	-- been written to DataStore.
	--
	-- These get reset to 0 when SaveData is replaced, so they are not sufficient
	-- for robustly tracking whether data has been saved or not. In order to 
	-- robustly check whether data has been saved you should use 
	-- LockerState:WhenChangesSaved() or LockerState:YieldUntilSaved().
	--
	ChangeId_Pending: number;
	ChangeId_PendingForce: number;
	ChangeId_Saved: number;
	SavedConnections: {SavedConnection};
	
	ProcessedRemoteChanges: {[number]: boolean};
	
	LoadStatus: LoadStatus;
	-- You could use this value in combination with MemoryStores to teleport 
	-- players to servers which a SaveData version of this value or higher, if
	-- a player's data fails to load due to it having an unknown version.
	LoadMinimumServerVersion: number?;
	SessionLoadState: SessionLoadState?;
	SessionState: SessionState?;
	
	--
	-- Methods
	--
	
	SessionUpdate: (LS: LockerState, HeartbeatNow: number)->(boolean);
	
	-- These two methods must be called to control the lifetime of the 
	-- LockerState. (Merely creating the LockerState will not start loading the
	-- data.)
	--
	-- LockerStates can be reused when a player leaves and rejoins the game. All 
	-- you need to do is make sure your code keeps track of LockerStates in a way
	-- that is independent of Player instances (e.g. track them by UserId 
	-- instead), then call these functions.
	MarkShouldAcquire: (LS: LockerState)->();
	MarkShouldRelease: (LS: LockerState)->();
	
	-- These two methods can be called to indicate to the module that save data 
	-- needs to be saved. It is also used to track "changes" to save data, so 
	-- that we can tell when a particular change saves (or fails to save) later.
	MarkShouldSave: (LS: LockerState)->();
	MarkForceSave: (LS: LockerState)->();
	
	-- Used to know when something is saved, after calling one of the above two
	-- functions.
	WhenChangesSaved: (
		LS: LockerState,
		Callback: (thread | (Saved: boolean, LS: LockerState, UserData: any)->())?,
		UserData: any?
	)->(SavedConnection);
	YieldUntilChangesSaved: (LS: LockerState)->(boolean);
	
	ProductCreditQuery: (LS: LockerState, ProductId: number)->(number);
	ProductCreditGive: (LS: LockerState, ProductId: number, Amount: number, UserData: any)->();
	ProductCreditUse: (LS: LockerState, ProductId: number, Amount: number, UserData: any)->(boolean);
}

--
-- Internal stuff (1)
--

local function UseSaveDataCreator(
	LockerSpec: LockerSpec,
	LogPrefix: string
)
	local Result = LockerSpec.SaveDataCreator()
	
	local Types = {
		{"Version", "number", 1 :: any};
		{"VersionPatch", "number", 0 :: any};
		{"ProductCredit", "table", {} :: any};
		{"Purchases", "table", {} :: any};
		{"Session", "nil", nil :: any}
	}
	
	local InvalidKeys = {}
	for _, Pair in Types do
		local Key = Pair[1]
		local Type = Pair[2]
		local Default = Pair[3]
		if type(Result[Key]) ~= Type then
			InvalidKeys[#InvalidKeys+1] = Pair
			Result[Key] = Default
		end
	end
	if InvalidKeys[1] then
		local O = {}
		O[#O+1] = ("%s SaveDataCreator returned SaveData with invalid or missing keys. They have been replaced with the following default values:"):format(LogPrefix)
		for _, Pair in InvalidKeys do
			local Key = Pair[1]
			local Default = Pair[3]
			O[#O+1] = "\n"
			O[#O+1] = ("\"%s\" = %s"):format(Key,
				if type(Default) == "table" then "{}" else tostring(Default))
		end
		warn(table.concat(O))
	end
	
	return Result
end

local function SessionReset(LS: LockerState, LifecycleReason: LifecycleReason)
	local SLS = LS.SessionLoadState
	if SLS then
		LS.SessionLoadState = nil
		
		assert(not SLS.Thread)
		assert(not SLS.Result)
	end
	
	local SS = LS.SessionState
	if SS then
		LS.SessionState = nil
		
		local SSS = SS.SessionSaveState
		if SSS then
			assert(not SSS.Thread)
			assert(not SSS.Result)
		end
	end
	
	local Changed = LS.LoadStatus ~= "loading"
	LS.LoadStatus = "loading"
	LS.LoadMinimumServerVersion = nil
	LS.ChangeId_Pending = 0
	LS.ChangeId_PendingForce = 0
	LS.ChangeId_Saved = 0
	
	if not LS.SavedConnections then
		LS.SavedConnections = {}
	end
	LS.ProcessedRemoteChanges = {}
	
	--[[ @DisableAPIs:ReplaceSaveData
	-- Use default save data before anything has loaded.
	LS.SaveData = UseSaveDataCreator(LS.LockerSpec, LS.LogPrefix)
	--]]
	---[[ @DisableAPIs:MaintainSaveData
	-- If DisableAPIs is enabled, the save data table should never get replaced
	-- after it has been created for the first time.
	if not LS.DisableAPIs or not LS.SaveData then
		
		-- Use default save data before anything has loaded.
		LS.SaveData = UseSaveDataCreator(LS.LockerSpec, LS.LogPrefix)
	end
	--]]
	
	if LS.LockerSpec.Lifecycle then
		LS.LockerSpec.Lifecycle(LS, "replaced", LifecycleReason)
	end
	
	-- Trigger all SavedConnections.
	do
		local Clone = table.clone(LS.SavedConnections)
		table.clear(LS.SavedConnections)
		for Index = #Clone, 1, -1 do
			local SC = Clone[Index]
			Module.SC_Trigger(SC, false)
		end
	end
	
	if Changed and
		LS.LockerSpec.LoadStatusChanged
	then
		LS.LockerSpec.LoadStatusChanged(LS)
	end
end

--
-- External API stuff (1)
--

function Module.LS_MarkShouldAcquire(LS: LockerState, Key: any?)
	local ActualKey = Key or "__SessionLocker"
	LS.InUse[ActualKey] = true
end
function Module.LS_MarkShouldRelease(LS: LockerState, Key: any?)
	local ActualKey = Key or "__SessionLocker"
	LS.InUse[ActualKey] = nil
end

function Module.LS_MarkShouldSave(LS: LockerState)
	-- Indicate that data should save on the next autosave. This doesn't have any
	-- effect on data saving at the moment, as autosaves will always be 
	-- performed in order to maintain the session lock.
	LS.ChangeId_Pending += 1
end
function Module.LS_MarkForceSave(LS: LockerState)
	-- Indicate that data should be saved immediately.
	LS.ChangeId_Pending += 1
	LS.ChangeId_PendingForce = LS.ChangeId_Pending
end

type SavedConnection = {
	LS: LockerState;
	ChangeId: number;
	DebugTraceback: string;
	
	Saved: boolean;
	Connected: boolean;
	
	Callback: (thread | (Saved: boolean, LS: LockerState, UserData: any)->())?;
	UserData: any?;
	
	Trigger: (SC: SavedConnection, Saved: boolean)->();
	Destroy: (SC: SavedConnection)->();
	Disconnect: (SC: SavedConnection)->();
}
function Module.SC_Trigger(SC: SavedConnection, Saved: boolean)
	if SC.Connected then
		SC.Connected = false
		local Index = table.find(SC.LS.SavedConnections, SC)
		if Index then
			table.remove(SC.LS.SavedConnections, Index)
		end
		
		SC.Saved = Saved
		
		local Valid = false
		if type(SC.Callback) == "function" then
			Valid = true
			
		elseif type(SC.Callback) == "thread" then
			local Status = coroutine.status(SC.Callback)
			
			if Status == "suspended" then
				Valid = true
				
			elseif Status == "dead" then
				warn(("[LockerState:WhenChangesSaved] SavedConnection.Callback is a dead thread. Did you forget to call SavedConnection:Destroy()/Disconnect()?\n\nOriginal Traceback:\n%s"):format(SC.DebugTraceback))
				
			elseif Status == "normal" then
				warn(("[LockerState:WhenChangesSaved] SavedConnection.Callback is an active thread. Did you forget to call SavedConnection:Destroy()/Disconnect()?\n\nOriginal Traceback:\n%s"):format(SC.DebugTraceback))
				
			elseif Status == "running" then
				warn(("[LockerState:WhenChangesSaved] SavedConnection.Callback is a running thread. Did you forget to call SavedConnection:Destroy()/Disconnect()? Are you calling SavedConnection:Trigger() in the wrong place?\n\nOriginal Traceback:\n%s\n\nCurrent Traceback:\n%s"):format(SC.DebugTraceback, debug.traceback(nil, 2)))
				
			else
				error(("Unknown coroutine status: %s"):format(Status))
			end
		end
		if Valid then
			-- Thread is deferred so that there is no wasted time repeatedly 
			-- creating & destroying SavedConnections as a result of the callback 
			-- executing immediately when the save data is going through a whole 
			-- lifecycle in a single frame.
			task.defer(SC.Callback :: any, SC.Saved, SC.LS, SC.UserData)
		end
	end
end
function Module.SC_Destroy(SC: SavedConnection)
	if SC.Connected then
		SC.Connected = false
		local Index = table.find(SC.LS.SavedConnections, SC)
		if Index then
			table.remove(SC.LS.SavedConnections, Index)
		end
	end
end

-- Call this when you want to know when the current SaveData (identified by the 
-- current LockerState.ChangeId_Pending) has been fully saved to the DataStore. 
-- Don't forget to call MarkShouldSave() or MarkForceSave() when your code 
-- modifies SaveData (and before you call this function) so that this function 
-- will work! You can also call this function without providing a callback, in 
-- which case you will need to poll SavedConnection.Saved and 
-- SavedConnection.Connected to see when things happen.
function Module.LS_WhenChangesSaved(
	LS: LockerState,
	
	-- Callback will be called every time something has happened that would 
	-- affect whether the data is saved or not. You should check ChangeStatus to 
	-- see what happened, and respond appropriately.
	Callback: (thread | (Saved: boolean, LS: LockerState, UserData: any)->())?,
	UserData: any?
	
): SavedConnection
	
	local SC = {} :: SavedConnection
	
	SC.LS = LS
	SC.ChangeId = LS.ChangeId_Pending
	SC.DebugTraceback = debug.traceback(nil, 2)
	
	SC.Callback = Callback
	SC.UserData = UserData
	
	-- Callback is deferred so that calling code does not break if the
	-- callback is executed immediately (e.g. before cleanup code has been
	-- set up). This works even if Callback == coroutine.running()!
	
	if LS.IsRemoved then
		SC.Saved = false
		SC.Connected = false
		
		if SC.Callback then
			task.defer(SC.Callback, SC.Saved, SC.LS, SC.UserData)
		end
		
	elseif LS.ChangeId_Pending <= LS.ChangeId_Saved then
		SC.Saved = true
		SC.Connected = false
		
		if SC.Callback then
			task.defer(SC.Callback, SC.Saved, SC.LS, SC.UserData)
		end
		
	else
		SC.Saved = false
		SC.Connected = true
		
		LS.SavedConnections[#LS.SavedConnections+1] = SC
	end
	
	SC.Trigger = Module.SC_Trigger
	SC.Destroy = Module.SC_Destroy
	SC.Disconnect = Module.SC_Destroy
	
	return SC
end

function Module.LS_YieldUntilChangesSaved(LS: LockerState): boolean
	local Saved
	if LS.IsRemoved then
		Saved = false
	elseif LS.ChangeId_Pending == LS.ChangeId_Saved then
		Saved = true
	else
		local SC = Module.LS_WhenChangesSaved(LS, coroutine.running())
		Saved = coroutine.yield()
	end
	return Saved
end

function Module.LS_ProductCreditQuery(
	LS: LockerState,
	ProductId: number
): number
	local Credit = 0
	local ProductCredit = LS.SaveData.ProductCredit
	if ProductCredit then
		for ProductIndex, Product in ProductCredit do
			if Product[1] == ProductId then
				Credit = Product[2]
				break
			end
		end
	end
	return Credit
end

function Module.LS_ProductCreditGive(
	LS: LockerState,
	ProductId: number,
	Amount: number,
	UserData: any
)
	if Amount ~= 0 then
		local SD = LS.SaveData
		local Array: {SD_ProductCredit} = SD.ProductCredit or {}
		SD.ProductCredit = Array
		local Found = false
		for _, Entry in Array do
			if Entry[1] == ProductId then
				Entry[2] += Amount
				Found = true
				break
			end
		end
		if not Found then
			Array[#Array+1] = {ProductId, Amount :: number}
		end
		if LS.LockerSpec.ProductCreditChanged then
			LS.LockerSpec.ProductCreditChanged(LS, SD, ProductId, Amount, UserData)
		end
	end
end

function Module.LS_ProductCreditUse(
	LS: LockerState,
	ProductId: number,
	Amount: number,
	UserData: any
): boolean
	
	local UsedCredit = false
	local ProductCredit = LS.SaveData.ProductCredit
	if ProductCredit then
		for ProductIndex, Product in ProductCredit do
			if Product[1] == ProductId then
				local Count = Product[2]
				if Count >= Amount then
					Count -= Amount
					UsedCredit = true
				end
				if Count <= 0 then
					table.remove(ProductCredit, ProductIndex)
				else
					Product[2] = Count
				end
				LS.ChangeId_Pending += 1
				if LS.LockerSpec.ProductCreditChanged then
					LS.LockerSpec.ProductCreditChanged(LS, LS.SaveData, ProductId, -Amount, UserData)
				end
				break
			end
		end
	end
	return UsedCredit
end

function Module.LockerCreate(
	LockerSpec: LockerSpec,
	DataStoreKey: string, -- The key save data is stored under.
	AssociatedUserIds: {number}, -- UserIds to associate with the DataStore key.
	LogPrefix: string?, -- The prefix used when outputting logs.
	DisableAPIs: boolean? -- Disable all DataStore & save/load behavior.
)
	local LS = {} :: LockerState
	LS.AssociatedUserIds = AssociatedUserIds
	LS.LockerSpec = LockerSpec
	LS.DataStoreKey = DataStoreKey 
	LS.LogPrefix = LogPrefix or ("[SessionLocker]["..DataStoreKey.."]")
	LS.DisableAPIs = DisableAPIs
	LS.InUse = {}
	LS.IsRemoved = false
	SessionReset(LS, "r_released")
	
	LS.SessionUpdate = Module.LS_SessionUpdate
	LS.MarkShouldAcquire = Module.LS_MarkShouldAcquire
	LS.MarkShouldRelease = Module.LS_MarkShouldRelease
	LS.MarkShouldSave = Module.LS_MarkShouldSave
	LS.MarkForceSave = Module.LS_MarkForceSave
	LS.WhenChangesSaved = Module.LS_WhenChangesSaved
	LS.YieldUntilChangesSaved = Module.LS_YieldUntilChangesSaved
	
	LS.ProductCreditQuery = Module.LS_ProductCreditQuery
	LS.ProductCreditGive = Module.LS_ProductCreditGive
	LS.ProductCreditUse = Module.LS_ProductCreditUse
	
	return LS
end

function Module.LockerCreatePlayer(
	LockerSpec: LockerSpec,
	Player: Player,
	DataStoreKey: string?,
	LogPrefix: string?,
	DisableAPIs: boolean?
)
	return Module.LockerCreate(
		LockerSpec,
		DataStoreKey or string.format("%i", Player.UserId),
		{Player.UserId},
		LogPrefix or Module.LogPrefixCreate(true, Player.UserId),
		DisableAPIs)
end

--
-- Internal stuff (2)
--

local function ProcessRemoteChanges(LS: LockerState): boolean
	
	local DidChangeSomething = false
	local SD = LS.SaveData
	
	local ProcessFunction = LS.LockerSpec.ProcessRemoteChange
	if ProcessFunction and SD.RemoteChanges then
		
		local RemainingRCs = {}
		for _, RC in SD.RemoteChanges do
			local Processed = ProcessFunction(SD, RC)
			if Processed then
				LS.ProcessedRemoteChanges[RC.I] = true
				DidChangeSomething = true
			else
				RemainingRCs[#RemainingRCs+1] = RC
			end
		end
		table.clear(SD.RemoteChanges)
		table.move(RemainingRCs, 1, #RemainingRCs, 1, SD.RemoteChanges)
	end
	
	if DidChangeSomething then
		Module.LS_MarkShouldSave(LS)
	end
		
	return DidChangeSomething
end


local function DoMigration(
	LogPrefix: string,
	Data: {Version: number, VersionPatch: number},
	
	LogDataIdentifier: string,
	ServerVersion: number,
	Migrators: {[number]: SaveDataMigrator},
	Patchers: {[number]: SaveDataPatcher},
	VerboseLogs: boolean
	
): (boolean, number?)
	
	local Success = true
	local MinimumServerVersion: number?
	
	local OriginalVersion = Data.Version
	local OriginalVersionPatch = Data.VersionPatch
	
	if not Data.Version then
		Data.Version = 0
	end
	if not Data.VersionPatch then
		Data.VersionPatch = 0
	end
	
	if (type(Data.Version) ~= "number") or
		(type(Data.VersionPatch) ~= "number")
	then
		if VerboseLogs then
			warn(("%s Invalid %s version (type is not 'number'). Version: '%s' (type '%s'), VersionPatch: '%s' (type '%s')."):format(
				LogPrefix,
				LogDataIdentifier,
				tostring(Data.Version),
				type(Data.Version),
				tostring(Data.VersionPatch),
				type(Data.VersionPatch)))
		end
		Success = false
		
	else
		
		-- Execute Patcher first to prevent any fixable problems from propagating 
		-- into later Versions.
		local Patcher = Patchers[Data.Version]
		if Patcher then
			Data.VersionPatch = Patcher(Data, Data.VersionPatch)
		end
		
		-- Runs data through all of the Migrator until its Version matches the 
		-- server's Version.
		while Data.Version ~= ServerVersion do
			local Migrator = Migrators[Data.Version]
			if Migrator then
				Data.VersionPatch = Migrator(Data)
				Data.Version += 1
				
			else
				-- @TODO This log here may be useful for users of the library to 
				-- debug problems. Should it be turned into more than just an 
				-- internal thing?
				if VerboseLogs then
					warn(("%s Invalid %s version (it doesn't have a migrator). Version is '%s_%s', original version is '%s_%s', server version is '%s'."):format(
						LogPrefix,
						LogDataIdentifier,
						tostring(Data.Version),
						tostring(Data.VersionPatch),
						tostring(OriginalVersion),
						tostring(OriginalVersionPatch),
						tostring(ServerVersion)))
				end
				Success = false
				MinimumServerVersion = Data.Version
				break
			end
		end
	end
	
	if Success and VerboseLogs then
		print(("%s Migrated %s from version '%s_%s' to version '%s_%s'"):format(
			LogPrefix,
			LogDataIdentifier,
			tostring(OriginalVersion),
			tostring(OriginalVersionPatch),
			tostring(Data.Version),
			tostring(Data.VersionPatch)))
	end
	
	return Success, MinimumServerVersion
end

-- @UpdateAsyncTransformFunction Luau errors that occur inside an UpdateAsync 
-- transform function will not throw an error on the calling thread. Instead, 
-- the UpdateAsync will succeed, so the error will not be detectable by the 
-- pcall(). Instead, you will need to manually detect such errors by having a 
-- "transform success" variable (or equivalent) that gets set to "true" right 
-- before returning from the transform function. This variable must also be 
-- reset to "false" INSIDE the transform function every time it runs, because 
-- the transform function may be called multiple times for a single call of 
-- :UpdateAsync().

local function SLS_Job(
	LS: LockerState,
	SLS: SessionLoadState
)
	local Result = {} :: SLS_Result
	
	local LSpec = LS.LockerSpec
	
	if LS.DisableAPIs then
		--[[ @DisableAPIs:ReplaceSaveData
		Result.SaveData = UseSaveDataCreator(LockerSpec, LS.LogPrefix)
		--]]
		---[[ @DisableAPIs:MaintainSaveData
		-- Keep the same template save data, so any changes to it don't get 
		-- replaced (e.g. if the usage code wanted to customize the save data of 
		-- fake players).
		Result.SaveData = LS.SaveData
		--]]
		Result.SaveData.Session = SessionCreate()
		Result.LoadStatus = "loaded"
		
	else
		
		-- See @UpdateAsyncTransformFunction
		local TransformedResult: SLS_Result? = nil

		local function TransformFunction(
			RemoteSD: SaveData?
		): (SaveData?, {number}?)
			
			TransformedResult = nil
			
			local NewResult = {} :: SLS_Result
			
			if not RemoteSD then
				NewResult.SaveData = UseSaveDataCreator(LSpec, LS.LogPrefix)
				NewResult.SaveData.Session = SessionCreate()
				NewResult.LoadStatus = "loaded"
				
			else
				if (RemoteSD.Session) and
					(not SessionExpired(RemoteSD.Session, LSpec))
				then
					NewResult.LoadStatus = "session_is_locked"
					
				else
					local MigrateSuccess, MinimumServerVersion = DoMigration(
						LS.LogPrefix,
						RemoteSD,
						"SaveData",
						LSpec.SaveDataVersion,
						LSpec.SaveDataMigrators,
						LSpec.SaveDataPatchers,
						Module.QueryConfig(
							LSpec.VerboseLogs, Module.Default_VerboseLogs))
					
					if not MigrateSuccess then
						NewResult.LoadStatus = "invalid_version"
						NewResult.MinimumServerVersion = MinimumServerVersion
						
					else
						NewResult.SaveData = RemoteSD
						NewResult.SaveData.Session = SessionCreate()
						NewResult.LoadStatus = "loaded"
					end
				end
			end
			
			TransformedResult = NewResult
			
			if (NewResult.LoadStatus == "loaded") and
				(not Module.QueryConfig(
					LSpec.ReadOnlyDataStores, Module.Default_ReadOnlyDataStores))
			then
				-- Note: If saving is disabled then the code making the request cannot 
				-- rely on the returned SaveData having particular values set by the 
				-- request (e.g. the session value, or migrated data).
				return NewResult.SaveData, LS.AssociatedUserIds
			else
				return nil
			end
		end
		
		local RequestSuccess, RequestMessage = pcall(function()
			Result.SaveData = LSpec.DataStore:UpdateAsync(
				LS.DataStoreKey,
				TransformFunction)
		end)
		
		-- If request failed then we just do nothing except report the error.
		if not RequestSuccess then
			Result.LoadStatus = "data_store_request_fail"
			
			if LSpec.ReportDataStoreError then
				LSpec.ReportDataStoreError(
					LS, "UpdateAsync_Load", RequestMessage)
			end
		
		elseif not TransformedResult then
			Result.LoadStatus = "data_store_request_fail"
		
		else
			Result.LoadStatus = TransformedResult.LoadStatus
			Result.MinimumServerVersion = TransformedResult.MinimumServerVersion
			
			-- If saving is not enabled (i.e. the UpdateAsync transform function 
			-- returned nil, cancelling the update) then the data won't have been 
			-- returned by UpdateAsync, so we need to manually set it here.
			if (TransformedResult.LoadStatus == "loaded") and
				(Module.QueryConfig(
					LSpec.ReadOnlyDataStores, Module.Default_ReadOnlyDataStores))
			then
				Result.SaveData = TransformedResult.SaveData
			end
		end
		
	end
	
	SLS.Result = Result
	SLS.Thread = nil
end

local function PerformSessionLoad(
	LS: LockerState,
	HeartbeatNow: number,
	LoadNewSession: boolean
)
	local LSpec = LS.LockerSpec
	
	while true do
		local SLS = LS.SessionLoadState :: SessionLoadState 
		if not SLS then
			if not LoadNewSession then
				break
			else
				local SLS: SessionLoadState = {
					NextAttemptAt = -math.huge;
				}
				LS.SessionLoadState = SLS
			end
		
		elseif SLS.Thread then
			break
			
		elseif not SLS.Result then
			if not LoadNewSession then
				LS.SessionLoadState = nil
				break
				
			elseif HeartbeatNow < SLS.NextAttemptAt then
				break
				
			else
				local Thread = coroutine.create(SLS_Job)
				SLS.Thread = Thread
				task.spawn(Thread, LS, SLS)
			end
		
		else
			local Result = SLS.Result
			SLS.Result = nil
			SLS.NextAttemptAt = -math.huge
			
			local Changed = LS.LoadStatus ~= Result.LoadStatus
			LS.LoadStatus = Result.LoadStatus
			
			-- If the load failed due to an invalid version, we don't attempt any 
			-- retries, we just forget about it.
			if Result.LoadStatus == "invalid_version" then
				SLS.NextAttemptAt = math.huge
				LS.LoadMinimumServerVersion = Result.MinimumServerVersion
				if Changed and
					LSpec.LoadStatusChanged
				then
					LSpec.LoadStatusChanged(LS)
				end
				
			-- If the load failed for a different reason then we just keep 
			-- retrying.
			elseif Result.LoadStatus ~= "loaded" then
				SLS.NextAttemptAt = HeartbeatNow + Module.QueryConfig(
					LSpec.SessionRetryCooldown, Module.Default_SessionRetryCooldown)
				if Changed and
					LSpec.LoadStatusChanged
				then
					LSpec.LoadStatusChanged(LS)
				end
			
			-- Otherwise if the load succeeded, we can be happy.
			else
				local SD = Result.SaveData
				assert(SD)
				assert(SD.Session)
				
				local SS: SessionState = {
					Session = SD.Session;
					AutosaveAt = HeartbeatNow + Module.QueryConfig(
						LSpec.MaintainSessionPeriod, Module.Default_MaintainSessionPeriod);
				}
				LS.SessionState = SS
				
				-- Process newly loaded remote changes.
				ProcessRemoteChanges(LS)
				
				-- Merge local changes into the new save data table.
				if LSpec.MergeOfflineSaveDataWithLoadedSaveData then
					LSpec.MergeOfflineSaveDataWithLoadedSaveData(
						LS, LS.SaveData, SD)
				end
				
				LS.SaveData = SD
				LS.SessionLoadState = nil
				
				if LS.LockerSpec.Lifecycle then
					LS.LockerSpec.Lifecycle(LS, "replaced", "r_loaded")
				end
				
				if Changed and
					LSpec.LoadStatusChanged
				then
					LSpec.LoadStatusChanged(LS)
				end
				
				break
			end
		end
	end
end

local function SSS_Job(
	LS: LockerState,
	SS: SessionState,
	SSS: SessionSaveState
)
	local LSpec = LS.LockerSpec
	
	if LS.DisableAPIs then
		SSS.Result = {
			RequestSuccess = true;
			LostSessionLock = false;
			SessionReleased = SSS.ShouldReleaseSession;
			SessionAt = if SSS.ShouldReleaseSession then nil :: any else os.time();
			ChangeId = LS.ChangeId_Pending;
			ProcessedRemoteChanges = table.clone(LS.ProcessedRemoteChanges);
		}
	else
		
		-- See @UpdateAsyncTransformFunction
		local TransformSuccess = false
		local TransformChangeId: number = nil
		local TransformSessionReleased: boolean = nil
		local TransformSessionAt: number = nil
		local TransformProcessedRemoteChanges: {[number]: boolean} = nil
		
		local function TransformFunction(RemoteSD): (SaveData?, {number}?)
			TransformSuccess = false
			
			local ChangeId = LS.ChangeId_Pending
			
			-- Used to check whether a remote change should be deleted or not.
			local ProcessedRemoteChanges = table.clone(LS.ProcessedRemoteChanges)
			
			-- TransformSD should be suitable to completely overwrite RemoteSD, 
			-- except for remote changes which will get moved into TransformSD.
			local TransformSD = Module.TableDeepCopy(LS.SaveData)
			
			TransformChangeId = ChangeId
			TransformSessionReleased = SSS.ShouldReleaseSession
			TransformProcessedRemoteChanges = ProcessedRemoteChanges
			
			if (RemoteSD) and (
					(RemoteSD.Version ~= TransformSD.Version) or
					(not RemoteSD.Session) or
					(not SessionEqual(RemoteSD.Session, SS.Session))
				)
			then
				warn(("%s Another session has taken a lock on save data.")
					:format(LS.LogPrefix))
			
			else
				
				if TransformSessionReleased then
					TransformSD.Session = nil
				else
					local ClonedSession = table.clone(SS.Session)
					ClonedSession.UpdatedAt = os.time()
					TransformSessionAt = ClonedSession.UpdatedAt
					TransformSD.Session = ClonedSession
				end
				
				if RemoteSD then
					local NewRemoteChanges = {}
					local OldRemoteChanges = RemoteSD.RemoteChanges
					if OldRemoteChanges then
						for _, RemoteChange in OldRemoteChanges do
							if not ProcessedRemoteChanges[RemoteChange.I] then
								NewRemoteChanges[#NewRemoteChanges+1] = RemoteChange
							end
						end
					end
					TransformSD.RemoteChanges =
						if NewRemoteChanges[1] then NewRemoteChanges else nil
				end
				
				TransformSuccess = true
			end
			
			if TransformSuccess then
				return TransformSD, LS.AssociatedUserIds
			else
				return nil
			end
		end
		
		local NewPSD
		
		local RequestSuccess, RequestMessage = pcall(function()
			if not Module.QueryConfig(
					LSpec.ReadOnlyDataStores, Module.Default_ReadOnlyDataStores)
			then
				NewPSD = LSpec.DataStore:UpdateAsync(
					LS.DataStoreKey,
					TransformFunction)
			else
				TransformSuccess = true
				TransformChangeId = LS.ChangeId_Pending
				TransformProcessedRemoteChanges = table.clone(LS.ProcessedRemoteChanges)
				TransformSessionReleased = SSS.ShouldReleaseSession
				TransformSessionAt = if TransformSessionReleased then nil :: any else os.time()
				NewPSD = {RemoteChanges = nil}
			end
		end)
		
		-- If request failed then we just do nothing except report the error if
		-- it's nontrivial.
		if not RequestSuccess then
			
			if LSpec.ReportDataStoreError then
				LSpec.ReportDataStoreError(
					LS, "UpdateAsync_Save", RequestMessage)
			end
		end
		
		SSS.Result = {
			RequestSuccess = RequestSuccess;
			LostSessionLock = not TransformSuccess;
			SessionAt = TransformSessionAt;
			SessionReleased = TransformSessionReleased;
			ChangeId = TransformChangeId;
			ProcessedRemoteChanges = TransformProcessedRemoteChanges;
			ImportedRemoteChanges = if NewPSD then NewPSD.RemoteChanges else nil;
		}
	end
	SSS.Thread = nil
end

local function PerformSessionSave(
	LS: LockerState,
	SS: SessionState,
	HeartbeatNow: number,
	CanBeginNewSave: boolean,
	ShouldReleaseSession: boolean
)
	local LSpec = LS.LockerSpec
	
	while true do
		local SSS = SS.SessionSaveState :: SessionSaveState
		if not SSS then
			if not CanBeginNewSave then
				break
			else
				local SSS: SessionSaveState = {
					NextAttemptAt = -math.huge;
					
					-- This value always gets updated when there is an active thread,
					-- so that threads have no risk of seeing outdated state about 
					-- whether session should be released or not. (And therefore, 
					-- updating the value at any other time is pointless since it 
					-- will just be overwritten.)
					ShouldReleaseSession = false;
				}
				SS.SessionSaveState = SSS
			end
		
		elseif SSS.Thread then
			SSS.ShouldReleaseSession = ShouldReleaseSession
			break
			
		elseif not SSS.Result then
			if not CanBeginNewSave then
				SS.SessionSaveState = nil
				break
				
			elseif HeartbeatNow < SSS.NextAttemptAt then
				break
				
			else
				SSS.ShouldReleaseSession = ShouldReleaseSession
				
				local Thread = coroutine.create(SSS_Job)
				SSS.Thread = Thread
				task.spawn(Thread, LS, SS, SSS)
			end
		
		else
			local Result = SSS.Result
			SSS.Result = nil
			SSS.NextAttemptAt = -math.huge
			
			if not Result.RequestSuccess then
				SSS.NextAttemptAt = HeartbeatNow + Module.QueryConfig(
					LSpec.SessionRetryCooldown, Module.Default_SessionRetryCooldown)
				
			elseif Result.LostSessionLock then
				warn(("%s Save data session lock has been lost.")
					:format(LS.LogPrefix))
				
				SS.SessionSaveState = nil
				SessionReset(LS, "r_lost")
				
				break
				
			else
				assert(Result.ChangeId)
				
				-- Clear out all the remote changes whose consequences we have 
				-- succesfully saved.
				for Key in Result.ProcessedRemoteChanges do
					LS.ProcessedRemoteChanges[Key] = nil
				end
				
				-- Merge new remote changes we don't know about into our local copy 
				-- of the header.
				local ImportedRemoteChanges = Result.ImportedRemoteChanges
				if ImportedRemoteChanges then
					
					local DidAddSomething = false
					local LocalRemoteChanges = LS.SaveData.RemoteChanges
					if not LocalRemoteChanges then
						LS.SaveData.RemoteChanges = ImportedRemoteChanges
						DidAddSomething = (ImportedRemoteChanges ~= nil)
					else
						local AddedRemoteChanges = {}
						for _, RemoteChange in ImportedRemoteChanges do
							local Found = false
							for _, LocalRemoteChange in LocalRemoteChanges do
								if LocalRemoteChange.I == RemoteChange.I then
									Found = true
									break
								end
							end
							if not Found then
								AddedRemoteChanges[#AddedRemoteChanges+1] = RemoteChange
							end
						end
						table.move(
							AddedRemoteChanges, 1, #AddedRemoteChanges,
							#LocalRemoteChanges+1, LocalRemoteChanges)
						DidAddSomething = (AddedRemoteChanges[1] ~= nil)
					end
					
					-- Process these newly added remote changes.
					if DidAddSomething then
						ProcessRemoteChanges(LS)
					end
				end
				
				-- Update the highest saved ChangeId.
				LS.ChangeId_Saved = Result.ChangeId
				
				-- Trigger all SavedConnections.
				do
					local Clone = table.clone(LS.SavedConnections)
					for Index = #Clone, 1, -1 do
						local SC = Clone[Index]
						
						assert(SC.ChangeId <= LS.ChangeId_Pending)
						if SC.ChangeId <= LS.ChangeId_Saved then
							
							Module.SC_Trigger(SC, true)
						end
					end
				end
				
				if LS.LockerSpec.Lifecycle then
					LS.LockerSpec.Lifecycle(LS, "saved", "none")
				end
				
				if Result.SessionReleased then
					SessionReset(LS, "r_released")
					
				else
					assert(Result.SessionAt)
					SS.Session.UpdatedAt = Result.SessionAt
					SS.AutosaveAt = HeartbeatNow + Module.QueryConfig(
						LSpec.MaintainSessionPeriod, Module.Default_MaintainSessionPeriod)
				end
				
				SS.SessionSaveState = nil
				break
			end
		end
	end
	
end

--
-- External API stuff (2)
--

function Module.LS_SessionUpdate(LS: LockerState, HeartbeatNow: number): boolean
	if LS.IsRemoved then
		error("LockerState should never be reused after it has been removed! Make sure it is deleted immediately after LS:SessionUpdate() returns false.")
	end
	
	local ShouldRemove = false
	
	-- If we don't have session then we are either trying to load data or the 
	-- player has left the game.
	local SS = LS.SessionState
	if not SS then
		
		-- Since the player is in-game, kick off the load job if the player has
		-- been marked as being ready for save data. 
		if next(LS.InUse) then
			PerformSessionLoad(LS, HeartbeatNow, true)
		
		-- Otherwise, we don't have an active session. But we might still have 
		-- a load job in progress, in which case we need to wait for it to 
		-- complete.
		elseif LS.SessionLoadState then
			PerformSessionLoad(LS, HeartbeatNow, false)
		
		-- If we reach here then we know for sure we don't have an active 
		-- session so we can just remove everything immediately.
		else
			ShouldRemove = true
			LS.IsRemoved = true
			
			if LS.LockerSpec.Lifecycle then
				LS.LockerSpec.Lifecycle(LS, "destroyed", "none")
			end
			
			-- Trigger all SavedConnections.
			do
				local Clone = table.clone(LS.SavedConnections)
				table.clear(LS.SavedConnections)
				for Index = #Clone, 1, -1 do
					local SC = Clone[Index]
					Module.SC_Trigger(SC, false)
				end
			end
		end
	
	-- If we get here then the player is still in the game and is playing 
	-- normally.
	elseif next(LS.InUse) then
		PerformSessionSave(
			LS, SS, HeartbeatNow,
			(HeartbeatNow >= SS.AutosaveAt) or (LS.ChangeId_PendingForce > LS.ChangeId_Saved),
			false)
		
	-- Once the player has left the game, we try to save all changes to their 
	-- data.
	else
		PerformSessionSave(LS, SS, HeartbeatNow,
			true, true)
	end
	
	return ShouldRemove
end

--
-- Product Purchaser
--
-- This is an API for perfectly handling developer product purchases, providing 
-- facilities to make sure MarketplaceService.ProcessReceipt won't return until 
-- the save data has been guaranteed to be processed & saved, and enables products
-- to be processed multiple times if the product purchase failed to save.
--
-- This API also makes use of the LockerState's ProductCredit APIs in order to 
-- handle products that fail to be processed for some reason but which can still
-- be saved.

export type ReceiptInfo = {
	PurchaseId: string;
	PlayerId: number;
	ProductId: number;
	PlaceIdWherePurchased: number;
	CurrencySpent: number;
}

export type ProductOp = "validate" | "apply"
export type ProductProcessFunction = (
	Op: ProductOp,
	LS: LockerState,
	ProductId: number)
->(boolean)

export type PendingProductPurchase = {
	ProcessFunction: ProductProcessFunction;
	ReceiptInfo: ReceiptInfo;
	Thread: thread | PPP_Callback;
	
	-- Used internally
	SavedConnection: SavedConnection?;
}
export type PPP_Callback = (IsPurchaseGranted: boolean)->()

export type ProductPurchaser = {
	PPPs_ByLS: {[LockerState]: {PendingProductPurchase}};
	
	Destroy: (PP: ProductPurchaser)->();
	Update: (PP: ProductPurchaser)->();
	
	CallWhenProductIsProcessedAndSaved: (
		PP: ProductPurchaser,
		LS: LockerState,
		PF: ProductProcessFunction,
		ReceiptInfo: ReceiptInfo,
		Callback: (IsPurchaseGranted: boolean)->()
	)->();
	
	-- Call this from the MarketplaceService.ProcessReceipt callback, and use the
	-- result to decide whether to mark the product as PurchaseGranted (if it 
	-- saved) or NotProcessedYet (if it did not save).
	YieldUntilProductIsProcessedAndSaved: (
		PP: ProductPurchaser,
		LS: LockerState,
		PF: ProductProcessFunction,
		ReceiptInfo: ReceiptInfo
	)->(boolean);
}

function Module.ProductPurchaserCreate(): ProductPurchaser
	local PP = {} :: ProductPurchaser
	PP.PPPs_ByLS = {}
	
	PP.Destroy = Module.PP_Destroy
	PP.Update = Module.PP_Update
	PP.CallWhenProductIsProcessedAndSaved = Module.PP_CallWhenProductIsProcessedAndSaved
	PP.YieldUntilProductIsProcessedAndSaved = Module.PP_YieldUntilProductIsProcessedAndSaved
	
	return PP
end
function Module.PP_Destroy(PP: ProductPurchaser)
	local Threads_False = {} :: {thread | PPP_Callback}
	for _, PPPs in PP.PPPs_ByLS do
		for _, PPP in PPPs do
			Threads_False[#Threads_False+1] = PPP.Thread
		end
		table.clear(PPPs)
	end
	table.clear(PP.PPPs_ByLS)
	for _, Thread in Threads_False do
		task.spawn(Thread, false)
	end
end
function Module.PP_CallWhenProductIsProcessedAndSaved(
	PP: ProductPurchaser,
	LS: LockerState,
	PF: ProductProcessFunction,
	ReceiptInfo: ReceiptInfo,
	Callback: (IsPurchaseGranted: boolean)->()
)
	PP.PPPs_ByLS[LS] = {
		ProcessFunction = PF;
		ReceiptInfo = ReceiptInfo;
		Thread = Callback;
	}
end
function Module.PP_YieldUntilProductIsProcessedAndSaved(
	PP: ProductPurchaser,
	LS: LockerState,
	PF: ProductProcessFunction,
	ReceiptInfo: ReceiptInfo
)
	PP.PPPs_ByLS[LS] = {
		ProcessFunction = PF;
		ReceiptInfo = ReceiptInfo;
		Thread = coroutine.running();
	}
	local IsPurchaseGranted = coroutine.yield()
	return IsPurchaseGranted
end
function Module.PP_Update(PP: ProductPurchaser)
	local Threads_True = {} :: {thread | PPP_Callback}
	local Threads_False = {} :: {thread | PPP_Callback}
	
	for LS, PPPs in PP.PPPs_ByLS do
		for PPPIndex = #PPPs, 1, -1 do
			local PPP = PPPs[PPPIndex]
			
			while true do
				
				local SC = PPP.SavedConnection
				if SC then
					
					-- We're waiting for a save to happen
					if SC.Connected then
						break
					
					-- The save completed succesfully!
					elseif SC.Saved then
						Threads_True[#Threads_True+1] = PPP.Thread
						table.remove(PPPs, PPPIndex)
						break
						
					-- The save didn't happen, so we try again!
					else
						PPP.SavedConnection = nil
					end
					
				-- If the locker state has been removed, we just have to quit
				-- trying to process the product.
				elseif LS.IsRemoved then
					Threads_False[#Threads_False+1] = PPP.Thread
					table.remove(PPPs, PPPIndex)
					break
					
				-- If we are not ready to start processing product purchases yet
				-- then we just have to wait. We can only process products when
				-- we are working with real save data.
				elseif
					(not LS.SessionState) or 
					(LS.LoadStatus ~= "loaded")
				then
					break
					
				-- We're now ready to attempt to process the product.
				else
					local ProductId = PPP.ReceiptInfo.ProductId
					local PurchaseId = PPP.ReceiptInfo.PurchaseId
					local SD = LS.SaveData
					
					local Purchases: {SD_Purchase} = SD.Purchases or {}
					SD.Purchases = Purchases
					
					-- If the product has already been purchased then we just 
					-- immediately resume the purchase thread.
					local AlreadyProcessed = false
					for _, Purchase in Purchases do
						if Purchase[1] == ProductId and
							Purchase[2] == PurchaseId
						then
							AlreadyProcessed = true
							break
						end
					end
					if AlreadyProcessed then
						Threads_True[#Threads_True+1] = PPP.Thread
						table.remove(PPPs, PPPIndex)
						break
					else
						
						-- Add the product to purchase history.
						local Limit = Module.QueryConfig(
							LS.LockerSpec.PurchaseHistoryLimit,
							Module.Default_PurchaseHistoryLimit)
						if Purchases[Limit] then
							table.remove(Purchases, 1)
						end
						Purchases[#Purchases+1] = {ProductId, PurchaseId, os.time()}
						
						-- Attempt to apply the product. And if product application 
						-- fails, give the player credit for this product so they can 
						-- use it for free sometime.
						if not PPP.ProcessFunction("apply", LS, ProductId) then
							Module.LS_ProductCreditGive(LS, ProductId, 1)
						end
						
						Module.LS_MarkForceSave(LS)
						PPP.SavedConnection = Module.LS_WhenChangesSaved(LS)
					end
				end
			end
		end
		
		if not PPPs[1] then
			PP.PPPs_ByLS[LS] = nil
		end
	end
	
	for _, Thread in Threads_True do
		task.spawn(Thread, true)
	end
	for _, Thread in Threads_False do
		task.spawn(Thread, false)
	end
end

--
-- Remote Change Sender
--
-- This API is defined with the following features in mind:
--
-- Usage code only needs to define the RemoteChange's "K" field to create a 
-- valid Remote Change, all other fields are customizable. The "A" and "I" 
-- fields are also reserved for internal use and will be added when the Remote 
-- Change is being sent.
--
-- It is intended that you use the "K" field to identify remote changes and do 
-- all versioning. You should never have a the same "K" field with RemoteChanges
-- that have a different type signature or do something different. You should 
-- never modify a RemoteChange once it has been created, except to fix a bug in 
-- its implementation. If you need to make multiple versions of a RemoteChange, 
-- put something different in the "K" field, like "give_gold_v2".
--
-- e.g.
--[[

-- define what remote changes we know about:
type RemoteChange =
	RemoteChange_give_gold |
	RemoteChange_give_playtime
	
type RemoteChange_give_gold = {
	K: "give_gold";
	gold: number;
}

type RemoteChange_give_playtime = {
	K: "give_playtime";
	playtime: number;
}

-- define remote change handler code:
LSpec = {
	...

	ProcessRemoteChange = function(SD: SaveData, RC: RemoteChange)
		local Success = false
		
		if RC.K == "give_gold" then
			SD.gold += RC.gold
			Success = true
			
		elseif RC.K == "give_playtime" then
			SD.playtime += RC.playtime
			Success = true
			
		else
			-- If we get an unknown RemoteChange then we do nothing. (We keep it in
			-- the save data.)
		end
		
		return Success
	end;

	...
}

-- send remote change:
RCS:Send({
	K = "give_gold";
	gold = 100;
})
--]]

export type RemoteChangeSender = {
	LockerSpec: LockerSpec;
	CreateIfMissing: boolean?;
	LogPrefix: string;
	DisableAPIs: boolean?;
	RNG: Random;
	Job_ByDataStoreKey: {[string]: RCS_Job};
	
	ReportDataStoreError: ((
		RCS: RemoteChangeSender,
		DataStoreKey: string,
		OperationName: string,
		ErrorMessage: string
	)->())?;
	
	Destroy: (RCS: RemoteChangeSender)->();
	Update: (RCS: RemoteChangeSender, HeartbeatNow: number)->();
	IsSending: (RCS: RemoteChangeSender)->(boolean);
	Send: (RCS: RemoteChangeSender, DataStoreKey: string, RemoteChanges: {SD_RemoteChange_Base})->();
}
export type RCS_Job = {
	DataStoreKey: string;
	PendingRCs: {SD_RemoteChange};
	
	NextAttemptAt: number;
	Thread: thread?;
	Result: RCS_Job_Result?;
}
export type RCS_Job_Result = {
	Success: boolean;
	SentRCs: {SD_RemoteChange};
}

Module.Default_RemoteChangeSender_ReportDataStoreError = function(
	RCS: RemoteChangeSender,
	DataStoreKey: string,
	OperationName: string,
	ErrorMessage: string
)
	local Message = " ReportDataStoreError:\n"..tostring(ErrorMessage)
	
	-- If verbose logs are enabled, we give the error message with full details.
	local LSpec: LockerSpec = RCS.LockerSpec
	if Module.QueryConfig(LSpec.VerboseLogs, Module.Default_VerboseLogs) then
		local LogPrefix: string = RCS.LogPrefix
		warn(RCS.LogPrefix..Message)
		
	-- Otherwise, we filter out all identifying information and just give the
	-- generic message, if it isn't a known backend error.
	elseif Module.GetRequestErrorKind(ErrorMessage) ~= "backend" then
		
		local Filters = {}
		Filters[#Filters+1] = {DataStoreKey, "{datastorekey}"}
		warn("[SessionLocker]"..Module.GsubFilter(Message, Filters))
	end
end

function Module.RemoteChangeSenderCreate(
	LockerSpec: LockerSpec,
	CreateIfMissing: boolean?, -- Enables creating fresh save data if not exist.
	LogPrefix: string?, -- The prefix used when outputting logs.
	DisableAPIs: boolean? -- Disable all DataStore & save/load behavior.
): RemoteChangeSender
	
	local RCS = {} :: RemoteChangeSender
	RCS.LockerSpec = LockerSpec
	RCS.LogPrefix = LogPrefix or ("[SessionLocker:RemoteChangeSender]")
	RCS.DisableAPIs = DisableAPIs
	RCS.CreateIfMissing = CreateIfMissing
	RCS.RNG = Random.new()
	RCS.Job_ByDataStoreKey = {}
	
	RCS.IsSending = Module.RCS_IsSending
	RCS.Send = Module.RCS_Send
	RCS.Update = Module.RCS_Update
	
	return RCS
end

function Module.RCS_Send(
	RCS: RemoteChangeSender,
	DataStoreKey: string, -- The key save data is stored under.
	RemoteChanges: {SD_RemoteChange_Base} -- The remote changes to send.
)
	for _, RC in RemoteChanges do
		local RC_I: SD_RemoteChange_Internal = RC :: any
		if RC_I.A ~= nil or RC_I.I ~= nil then
			warn(debug.traceback("[SessionLocker] RemoteChange to send has A and/or I fields set, which are reserved for internal use. These fields will be overridden!"))
		end
		RC_I.A = os.time()
		-- The RemoteChange.I field will be set in the transform function.
	end
	
	local Job = RCS.Job_ByDataStoreKey[DataStoreKey]
	if Job then
		table.move(
			RemoteChanges, 1, #RemoteChanges,
			#Job.PendingRCs+1, Job.PendingRCs)
	else
		RCS.Job_ByDataStoreKey[DataStoreKey] = {
			DataStoreKey = DataStoreKey;
			PendingRCs = table.clone(RemoteChanges) :: {SD_RemoteChange};
			NextAttemptAt = -math.huge;
		}
	end
end
function Module.RCS_IsSending(RCS: RemoteChangeSender)
	return next(RCS.Job_ByDataStoreKey) ~= nil
end

local function RCS_Job_Function(RCS: RemoteChangeSender, Job: RCS_Job)
	local Result = {} :: RCS_Job_Result
	
	local LSpec = RCS.LockerSpec
	
	if RCS.DisableAPIs then
		Result.Success = true
		Result.SentRCs = table.clone(Job.PendingRCs)
	
	else
		
		local SentRCs = {}
		
		local function TransformFunction(
			RemoteSD: SaveData?, RemoteKeyInfo: DataStoreKeyInfo
		): (SaveData?, {number}?)
			
			local MadeChange = false
			
			SentRCs = {}
			
			if not RemoteSD and RCS.CreateIfMissing then
				RemoteSD = UseSaveDataCreator(LSpec, RCS.LogPrefix)
				MadeChange = true
			end
			
			if RemoteSD then
				
				local RemoteChanges: {SD_RemoteChange} = RemoteSD.RemoteChanges or {}
				RemoteSD.RemoteChanges = RemoteChanges
				
				local Used_ByI = {}
				for _, RC in RemoteChanges do
					Used_ByI[RC.I] = true
				end
				
				for _, RC in Job.PendingRCs do
					
					-- Give this RemoteChange a random unique ID, and keep regenerating the
					-- ID until no collisions are found (though they are extremely 
					-- unlikely in first place).
					do
						local NewUniqueId: number
						while true do
							NewUniqueId = RCS.RNG:NextInteger(0, 2^32-1)
							if not Used_ByI[NewUniqueId] then break end
						end
						RC.I = NewUniqueId
					end
					
					RemoteChanges[#RemoteChanges+1] = RC
					Used_ByI[RC.I] = true
					
					MadeChange = true
				end
			end
			
			if MadeChange and
				(not Module.QueryConfig(
					LSpec.ReadOnlyDataStores, Module.Default_ReadOnlyDataStores))
			then
				return RemoteSD, RemoteKeyInfo:GetUserIds()
			else
				return nil, nil
			end
		end
		
		local RequestSuccess, RequestMessage = pcall(function()
			LSpec.DataStore:UpdateAsync(Job.DataStoreKey, TransformFunction)
		end)
		
		-- If request failed then we just do nothing except report the error.
		if not RequestSuccess then
			Result.Success = false
			Result.SentRCs = {}
			
			if RCS.ReportDataStoreError then
				RCS.ReportDataStoreError(
					RCS, Job.DataStoreKey, "UpdateAsync_SendRemoteChanges", RequestMessage)
			end
			
		else
			Result.Success = true
			Result.SentRCs = SentRCs
		end
	end
	
	Job.Result = Result
	Job.Thread = nil
end

function Module.RCS_Update(RCS: RemoteChangeSender, HeartbeatNow: number)
	for _, Job in RCS.Job_ByDataStoreKey do
		while true do
			if not Job.PendingRCs[1] then
				RCS.Job_ByDataStoreKey[Job.DataStoreKey] = nil
				
			elseif Job.Result then
				local Result = Job.Result
				Job.NextAttemptAt = HeartbeatNow + 0.5
				
				if Result.Success then
					for SentIndex = #Result.SentRCs, 1, -1 do
						local SentRC = Result.SentRCs[SentIndex]
						local PendingIndex = table.find(Job.PendingRCs, SentRC)
						if PendingIndex then
							table.remove(Job.PendingRCs, PendingIndex)
						end
					end
				end
				
			-- Wait for operation to complete.
			elseif Job.Thread then
				break
				
			-- Wait until we can begin the job again.
			elseif Job.NextAttemptAt > HeartbeatNow then
				break
				
			-- Begin the job!
			else
				Job.Thread = coroutine.create(RCS_Job_Function)
				task.spawn(Job.Thread :: any, RCS, Job)
			end
		end
	end
end

--
-- Helper utility for building Migrators
--

export type MigratorBuilder = {
	-- Internal fields
	MaxVersion: number;
	Migrators: {[number]: SaveDataMigrator};
	Patchers: {[number]: SaveDataPatcher};
	
	-- Exposed methods
	AddMigratorFrom: (MB: MigratorBuilder, From: number, Migrator: SaveDataMigrator, Patcher: SaveDataPatcher?)->();
	AddPatcherFor: (MB: MigratorBuilder, For: number, Patcher: SaveDataPatcher)->();
	CheckVersion: (MB: MigratorBuilder, CurrentVersion: number)->();
	Build: (MB: MigratorBuilder)->({[number]: SaveDataMigrator}, {[number]: SaveDataPatcher});
}
function Module.MigratorBuilderCreate(): MigratorBuilder
	return {
		MaxVersion = -math.huge;
		Migrators = {};
		Patchers = {};
		
		AddMigratorFrom = Module.MB_AddMigratorFrom;
		AddPatcherFor = Module.MB_AddPatcherFor;
		CheckVersion = Module.MB_CheckVersion;
		Build = Module.MB_Build;
	} :: MigratorBuilder
end
function Module.MB_AddMigratorFrom(
	MB: MigratorBuilder,
	FromVersion: number,
	Migrator: SaveDataMigrator,
	Patcher: SaveDataPatcher?
)
	if MB.Migrators[FromVersion] then
		error(("MB_AddMigrator: Migrator from version %d already exists!"):format(FromVersion))
	end
	MB.Migrators[FromVersion] = Migrator
	MB.MaxVersion = math.max(MB.MaxVersion, FromVersion)
	if Patcher then
		Module.MB_AddPatcherFor(MB, FromVersion+1, Patcher)
	end
end
function Module.MB_AddPatcherFor(MB: MigratorBuilder, ForVersion: number, Patcher: SaveDataPatcher)
	if MB.Patchers[ForVersion] then
		error(("MB_AddPatcher: Patcher for version %d already exists!"):format(ForVersion))
	end
	MB.Patchers[ForVersion] = Patcher
end
function Module.MB_CheckVersion(MB: MigratorBuilder, CurrentVersion: number)
	if math.floor(CurrentVersion) ~= CurrentVersion then
		error(("MB_CheckVersion: Version must be an integer, instead got %s")
			:format(tostring(CurrentVersion)))
	end
	if CurrentVersion < 1 then
		error(("MB_CheckVersion: Version must be at least 1, instead got %s")
			:format(tostring(CurrentVersion)))
	end
	if CurrentVersion > 1 and not MB.Migrators[CurrentVersion-1] then
		error(("MB_CheckVersion: Version %d is missing a migrator."):format(CurrentVersion))
	end
	if MB.Migrators[CurrentVersion+1] then
		error(("MB_CheckVersion: A migrator is present for the next version %d, so the current version %d is likely out of date.")
			:format(CurrentVersion+1, CurrentVersion))
	end
end
function Module.MB_Build(
	MB: MigratorBuilder
): ({[number]: SaveDataMigrator}, {[number]: SaveDataPatcher})
	for Index = 1, MB.MaxVersion do
		if not MB.Migrators[Index] then
			warn(debug.traceback(
				("MB_Build: Missing a Migrator for version %d, generating no-op."):format(Index)))
			MB.Migrators[Index] = function() return 0 end
		end
	end
	for Index in MB.Patchers do
		if Index > MB.MaxVersion+1 then
			warn(debug.traceback(
				("MB_Build: Patcher defined for non-existent version %d"):format(Index)))
		end
	end
	return table.clone(MB.Migrators), table.clone(MB.Patchers)
end

--
-- EASY API (similar to other session locking modules):
--

export type EasyStore = {
	DataStore: DataStore;
	LSpec: LockerSpec;
	ELSs_ByKey: {[string]: {EasyLockerState}};
	RCS: RemoteChangeSender;
	
	--
	-- Methods
	--
	
	StartSession: (
		ES: EasyStore,
		DataStoreKey: string,
		AssociatedUserIds: {number}?,
		LogPrefix: string?,
		DisableAPIs: boolean?
	)->(EasyProfile);
	
	StartSessionReusable: (
		ES: EasyStore,
		DataStoreKey: string,
		AssociatedUserIds: {number}?,
		LogPrefix: string?,
		DisableAPIs: boolean?
	)->(EasyProfile);
	
	SendRemoteChanges: (
		ES: EasyStore,
		DataStoreKey: string,
		RemoteChanges: {SD_RemoteChange_Base}
	)->();
}

export type EasyProfile = {
	--
	-- Fields
	--
	
	ES: EasyStore;
	ELS: EasyLockerState;
	
	LoadYieldThreads: {thread};
	SaveYieldThreads: {{ChangeId: number, Thread: thread}};
	
	IsActive: boolean;
	IsLoaded: boolean;
	
	--
	-- Signals (deferred)
	--
	
	-- Signal relationships (fired in bottom-up order):
	--
	-- ProductCreditChanged
	--	Lifecycle
	--	|-	Destroyed
	--	|-	Saved
	-- |-	Replaced
	--		|-	Loaded
	--		|-	Reset
	--			|-	Released
	--			|-	Lost
	
	-- Fires when SaveData is replaced because session lock was unwillingly lost.
	-- (next signals: Reset, Replaced, Lifecycle)
	Lost: Signal; -- ()
	
	-- Fires when saveData is replaced because session lock was willingly released.
	-- (next signals: Reset, Replaced, Lifecycle)
	Released: Signal; -- ()
	
	-- Fires when SaveData is replaced by a default save data table.
	-- (next signals: Replaced, Lifecycle)
	Reset: Signal; -- (Reason)
	
	-- Fires when SaveData is replaced by loaded save data.
	-- (next signals: Replaced, Lifecycle)
	Loaded: Signal; -- ()
	
	-- Fires when SaveData is replaced by a different table.
	-- (next signals: Lifecycle)
	Replaced: Signal; -- (Reason)
	
	-- Fires when SaveData was saved.
	-- (next signals: Lifecycle)
	Saved: Signal; -- (Reason)
	
	-- Fires when SaveData will never be loaded again for this EasyProfile/LockerState.
	-- (next signals: Lifecycle)
	Destroyed: Signal;  -- (Reason)
	
	-- Fires when lifecycle of SaveData updates.
	Lifecycle: Signal; -- (Status, Reason)
	
	-- Fires when product credit changes.
	ProductCreditChanged: Signal; -- (ProductId, ChangeAmount, UserData)
		
	--
	-- Methods
	--
	
	GetSaveData: (EP: EasyProfile)->(SaveData);
	YieldUntilLoaded: (EP: EasyProfile)->(EasyProfile?);
	EndSession: (EP: EasyProfile)->();
	
	-- Wwrappers of methods in LockerState.
	
	MarkShouldSave: (EP: EasyProfile)->();
	MarkForceSave: (EP: EasyProfile)->();
	
	WhenChangesSaved: (
		EP: EasyProfile,
		-- Note this wrapper gives the callback the EasyProfile instead of the 
		-- LockerState.
		Callback: (thread | (Saved: boolean, EP: EasyProfile, UserData: any)->())?,
		UserData: any?
	)->(SavedConnection);
	YieldUntilChangesSaved: (EP: EasyProfile)->(boolean);
	
	ProductCreditQuery: (EP: EasyProfile, ProductId: number)->(number);
	ProductCreditGive: (EP: EasyProfile, ProductId: number, Amount: number, UserData: any)->();
	ProductCreditUse: (EP: EasyProfile, ProductId: number, Amount: number, UserData: any)->(boolean);
	
	-- Wrappers of methods in ProductPurchaser.
	
	CallWhenProductIsProcessedAndSaved: (
		EP: EasyProfile,
		PF: ProductProcessFunction,
		ReceiptInfo: ReceiptInfo,
		Callback: (IsPurchaseGranted: boolean)->()
	)->();
	YieldUntilProductIsProcessedAndSaved: (
		EP: EasyProfile,
		PF: ProductProcessFunction,
		ReceiptInfo: ReceiptInfo
	)->(boolean);
}

export type EasyLockerState = LockerState & {
	EPs: {EasyProfile};
}

local State = (function() return { -- Seal the table
	
	ServerInitialized = false;
	ServerClosing = false;
	
	ES_ByDataStore = {} :: {[DataStore]: EasyStore};
	PP = Module.ProductPurchaserCreate();
	
} end)()

local function EasyBindToClose()
	State.ServerClosing = true
	while true do
		local IsWorking = false
		for _, ES in State.ES_ByDataStore do
			if (next(ES.ELSs_ByKey) ~= nil) or
				(ES.RCS:IsSending())
			then
				IsWorking = true
				break
			end
		end
		if IsWorking then
			task.wait()
		else
			break
		end
	end
end

local function EasyHeartbeat()
	debug.profilebegin("SessionLocker_EasyHeartbeat")
	local HeartbeatNow = os.clock()
	
	for _, ES in State.ES_ByDataStore do
		
		if State.ServerClosing then
			for Key, ELSs in ES.ELSs_ByKey do
				for _, ELS in ELSs do
					for _, EP in ELS.EPs do
						Module.EP_EndSession(EP)
					end
				end
			end
		end
		
		for Key, ELSs in ES.ELSs_ByKey do
			local Remove = {}
			for Index, ELS in ELSs do
				local LS: LockerState = ELS :: any
				if Module.LS_SessionUpdate(LS, HeartbeatNow) then
					Remove[#Remove+1] = Index
				end
			end
			for Index = #Remove, 1, -1 do
				table.remove(ELSs, Remove[Index])
			end
			if not ELSs[1] then
				ES.ELSs_ByKey[Key] = nil
			end
		end
		
		Module.RCS_Update(ES.RCS, HeartbeatNow)
	end
	
	Module.PP_Update(State.PP)
	
	debug.profileend()
end

local function EasyLifecycleSingle(EP: EasyProfile, Status: LifecycleStatus, Reason: LifecycleReason)
	local LS = EP.ELS
	
	if Status == "replaced" then
				
		if Reason == "r_loaded" then
			EP.IsLoaded = true
			EP.Loaded:Fire()
			
			for _, Thread in EP.LoadYieldThreads do
				task.defer(Thread)
			end
			table.clear(EP.LoadYieldThreads)
			
		else
			EP.IsLoaded = false
			if Reason == "r_lost" then
				EP.Lost:Fire()
			elseif Reason == "r_released" then
				EP.Released:Fire()
			end
			
			EP.Reset:Fire(Reason)
		end
		
		EP.Replaced:Fire(Reason)
		
		for _, Group in EP.SaveYieldThreads do
			task.defer(Group.Thread)
		end
		table.clear(EP.SaveYieldThreads)
		
	elseif Status == "saved" then
		EP.Saved:Fire(Reason)
	
		for Index = #EP.SaveYieldThreads, 1, -1 do
			local Group = EP.SaveYieldThreads[Index]
			if Group.ChangeId <= LS.ChangeId_Saved then
				task.defer(Group.Thread, LS.ChangeId_Saved)
				table.remove(EP.SaveYieldThreads, Index)
			end
		end
		
	elseif Status == "destroyed" then
		EP.Destroyed:Fire(Reason)
		
		for _, Thread in EP.LoadYieldThreads do
			task.defer(Thread)
		end
		table.clear(EP.LoadYieldThreads)
		
		for _, Group in EP.SaveYieldThreads do
			task.defer(Group.Thread)
		end
		table.clear(EP.SaveYieldThreads)
	end
	
	EP.Lifecycle:Fire(Status, Reason)
end
local function EasyLifecycle(LS, Status: LifecycleStatus, Reason: LifecycleReason)
	local ELS: EasyLockerState = LS :: any
	if ELS.EPs then
		for _, EP in ELS.EPs do
			EasyLifecycleSingle(EP, Status, Reason)
		end
	end
end
local function EasyProductCreditChanged(LS, SD, ProductId, ChangeAmount, UserData)
	local ELS: EasyLockerState = LS :: any
	if ELS.EPs then
		for _, EP in ELS.EPs do
			EP.ProductCreditChanged:Fire(
				ProductId,
				ChangeAmount,
				UserData)
		end
	end
end

function Module.EasyStoreCreate(
	
	DataStore: DataStore,
	
	-- Function that creates your save data table.
	CreateSaveData: ()->({[any]: any}),
	
	-- Strict version of save data. Defaults & starts at 1. You must have a 
	-- migrator for every preceding version. Unknown versions will prevent 
	-- session from being acquired.
	SaveDataVersion: number?,
	
	-- Patch ID / version of a particular Version of SaveData. Useful for 
	-- recovering from recoverable mistakes in a Migrator (such as typos in field
	-- names, or forgetting to migrate a field). You can choose what values you
	-- use for this, but if not provided the default is 0.
	SaveDataVersionPatch: number?,
	
	-- Table of functions that perform migration. You can use MigratorBuilder to
	-- build these. Also see @MigratorDocs.
	Migrators: {[number]: SaveDataMigrator}?,
	Patchers: {[number]: SaveDataPatcher}?,
	
	-- Remote change processor function (see LockerSpec type's documentation for 
	-- more info.)
	ProcessRemoteChange: ((
		SD: any,
		RemoteChange: any
	)->(boolean))?
	
): EasyStore
	
	if game:GetService("RunService"):IsClient() then
		error("SessionLocker.EasyStoreCreate() cannot be called on the client.")
	end
	
	if State.ES_ByDataStore[DataStore] then
		warn(debug.traceback("WARNING: SessionLocker.EasyStoreCreate() was called with a DataStore that is already registered to an existing EasyStore. That EasyStore will be returned."))
	else
		
		do
			local Test = CreateSaveData()
			if Test.Version ~= nil or
				Test.VersionPatch ~= nil or
				Test.Purchases ~= nil or
				Test.ProductCredit ~= nil
			then
				warn(debug.traceback("WARNING: Provided CreateSaveData() function returned SaveData with one or more of the following SaveData fields: Version, VersionPatch, Purchases, ProductCredit. All of these fields will be overwritten, so you should not define them yourself."))
			end
		end
		
		local SD_Version = SaveDataVersion or 1
		local SD_VersionPatch = SaveDataVersionPatch or 0
		
		local LSpec: LockerSpec = {
			DataStore = DataStore;
			
			SaveDataVersion = SD_Version;
			SaveDataMigrators = Migrators or {};
			SaveDataPatchers = Patchers or {};
			SaveDataCreator = function(): SaveData
				local SaveData = CreateSaveData()
				SaveData.Version = SD_Version
				SaveData.VersionPatch = SD_VersionPatch
				SaveData.Purchases = {}
				SaveData.ProductCredit = {}
				return SaveData
			end;
			
			Lifecycle = EasyLifecycle;
			ProductCreditChanged = EasyProductCreditChanged;
			ReportDataStoreError = Module.Default_LockerSpec_ReportDataStoreError;
			ProcessRemoteChange = ProcessRemoteChange;
		}
		
		local RCS = Module.RemoteChangeSenderCreate(LSpec, true)
		RCS.ReportDataStoreError = Module.Default_RemoteChangeSender_ReportDataStoreError
		
		local ES: EasyStore = {
			DataStore = DataStore;
			LSpec = LSpec;
			ELSs_ByKey = {};
			RCS = RCS;
			
			StartSession = Module.ES_StartSession;
			StartSessionReusable = Module.ES_StartSessionReusable;
			SendRemoteChanges = Module.ES_SendRemoteChanges;
		}
		State.ES_ByDataStore[ES.DataStore] = ES
		
		if not State.ServerInitialized then
			game:GetService("RunService").Heartbeat:Connect(EasyHeartbeat)
			game:BindToClose(EasyBindToClose)
		end
	end
	
	return State.ES_ByDataStore[DataStore]
end

export type Signal = {
	Connections: {SignalConnection};
	
	Connect: (Signal: Signal, Callback: ()->())->(SignalConnection);
	Fire: (Signal: Signal, ...any)->();
	Destroy: (Signal: Signal)->();
	Wait: (Signal: Signal)->();
}
export type SignalConnection = {
	Signal: Signal;
	Callback: thread | ()->();
	Once: boolean?;
	Connected: boolean;
	
	Disconnect: (Conn: SignalConnection)->();
	Destroy: (Conn: SignalConnection)->();
}
local function SignalConnection_Disconnect(Conn: SignalConnection)
	if Conn.Connected then
		Conn.Connected = false
		
		local Signal = Conn.Signal
		local Index = table.find(Signal.Connections, Conn)
		if Index then
			table.remove(Signal.Connections, Index)
		end
	end
end
local function Signal_Connect(Signal: Signal, Callback: ()->()): SignalConnection
	local Conn: SignalConnection = {
		Signal = Signal;
		Callback = Callback;
		Connected = true;
		
		Disconnect = SignalConnection_Disconnect;
		Destroy = SignalConnection_Disconnect;
	}
	Signal.Connections[#Signal.Connections+1] = Conn
	return Conn
end
local function Signal_Once(Signal: Signal, Callback: ()->()): SignalConnection
	local Conn: SignalConnection = {
		Signal = Signal;
		Callback = Callback;
		Once = true;
		Connected = true;
		
		Disconnect = SignalConnection_Disconnect;
		Destroy = SignalConnection_Disconnect;
	}
	Signal.Connections[#Signal.Connections+1] = Conn
	return Conn
end
local function Signal_Wait(Signal: Signal)
	local Conn: SignalConnection = {
		Signal = Signal;
		Callback = coroutine.running();
		Once = true;
		Connected = true;
		
		Disconnect = SignalConnection_Disconnect;
		Destroy = SignalConnection_Disconnect;
	}
	Signal.Connections[#Signal.Connections+1] = Conn
	coroutine.yield()
end
local function Signal_Fire(Signal: Signal, ...: any)
	local Remove = {}
	for _, Conn in Signal.Connections do
		task.defer(Conn.Callback, ...)
		if Conn.Once then
			Remove[#Remove+1] = Conn
		end
	end
	for Index = #Remove, 1, -1 do
		local Conn = Remove[Index]
		Conn:Disconnect()
	end
end
local function Signal_Destroy(Signal: Signal)
	local Clone = table.clone(Signal.Connections)
	table.clear(Signal.Connections)
	for _, Conn in Clone do
		Conn:Disconnect()
	end
end
local function Signal_Create(): Signal
	local Signal: Signal = {
		Connections = {};
		
		Connect = Signal_Connect;
		Once = Signal_Once;
		Wait = Signal_Wait;
		Fire = Signal_Fire;
		Destroy = Signal_Destroy;
	}
	return Signal
end

-- You can override this with something else if you want to use a custom signal 
-- class.
Module.SignalCreate = Signal_Create

local function EP_Init(EP: EasyProfile)
	EP.IsActive = true
	EP.IsLoaded = false
	EP.LoadYieldThreads = {}
	EP.SaveYieldThreads = {}
	
	EP.ProductCreditChanged = Module.SignalCreate()
	EP.Lifecycle = Module.SignalCreate()
	EP.Destroyed = Module.SignalCreate()
	EP.Saved = Module.SignalCreate()
	EP.Replaced = Module.SignalCreate()
	EP.Loaded = Module.SignalCreate()
	EP.Reset = Module.SignalCreate()
	EP.Released = Module.SignalCreate()
	EP.Lost = Module.SignalCreate()
	
	EP.GetSaveData = Module.EP_GetSaveData
	EP.YieldUntilLoaded = Module.EP_YieldUntilLoaded
	EP.EndSession = Module.EP_EndSession
	
	EP.MarkForceSave = Module.EP_MarkForceSave
	EP.MarkShouldSave = Module.EP_MarkShouldSave
	EP.WhenChangesSaved = Module.EP_WhenChangesSaved
	EP.YieldUntilChangesSaved = Module.EP_YieldUntilChangesSaved
	
	EP.ProductCreditQuery = Module.EP_ProductCreditQuery
	EP.ProductCreditGive = Module.EP_ProductCreditGive
	EP.ProductCreditUse = Module.EP_ProductCreditUse
	
	EP.CallWhenProductIsProcessedAndSaved = Module.EP_CallWhenProductIsProcessedAndSaved
	EP.YieldUntilProductIsProcessedAndSaved = Module.EP_YieldUntilProductIsProcessedAndSaved
end

function Module.ES_StartSession(
	ES: EasyStore,
	DataStoreKey: string,
	AssociatedUserIds: {number}?,
	LogPrefix: string?,
	DisableAPIs: boolean?
)
	local ELS = Module.LockerCreate(
		ES.LSpec,
		DataStoreKey,
		AssociatedUserIds or {},
		LogPrefix,
		DisableAPIs) :: EasyLockerState
	
	local Array = ES.ELSs_ByKey[DataStoreKey]
	if Array then
		Array[#Array+1] = ELS
	else
		ES.ELSs_ByKey[DataStoreKey] = {ELS}
	end
	
	local EP = {} :: EasyProfile
	EP.ES = ES
	EP_Init(EP)
	
	EP.ELS = ELS
	if not EP.ELS.EPs then
		EP.ELS.EPs = {}
	end
	EP.ELS.EPs[#EP.ELS.EPs+1] = EP
	Module.LS_MarkShouldAcquire(EP.ELS)
	
	return EP
end

-- This function is the same as the above, except if a session is already active
-- for this key then that session's ELS will be taken and reused. Could save 
-- some unnecessary DataStore churn in some scenarios.
function Module.ES_StartSessionReusable(
	ES: EasyStore,
	DataStoreKey: string,
		
	-- NOTE: These arguments, will only be applied if the session gets started 
	-- from scratch. So make sure they will always be the same across sessions.
	AssociatedUserIds: {number}?,
	LogPrefix: string?,
	DisableAPIs: boolean?
)
	local Found: EasyLockerState
	do
		local Array = ES.ELSs_ByKey[DataStoreKey]
		if Array then
			for _, ELS in Array do
				if (not Found) or
					(
						(ELS.LoadStatus == "loaded") and
						(Found.LoadStatus ~= "loaded")
					)
				then
					Found = ELS :: EasyLockerState
				end
			end
		end
	end
	if not Found then
		
		local ELS: EasyLockerState = Module.LockerCreate(
			ES.LSpec,
			DataStoreKey,
			AssociatedUserIds or {},
			LogPrefix,
			DisableAPIs) :: EasyLockerState
		
		local Array = ES.ELSs_ByKey[DataStoreKey]
		if Array then
			Array[#Array+1] = ELS
		else
			ES.ELSs_ByKey[DataStoreKey] = {ELS}
		end
		
		Found = ELS
	end
	
	local EP = {} :: EasyProfile
	EP.ES = ES
	EP_Init(EP)
	
	EP.ELS = Found
	if not EP.ELS.EPs then
		EP.ELS.EPs = {}
	end
	EP.ELS.EPs[#EP.ELS.EPs+1] = EP
	Module.LS_MarkShouldAcquire(EP.ELS)
	
	return EP
end

function Module.ES_SendRemoteChanges(
	ES: EasyStore,
	DataStoreKey: string, -- The key save data is stored under.
	RemoteChanges: {SD_RemoteChange_Base} -- The remote changes to send.
)
	Module.RCS_Send(ES.RCS, DataStoreKey, RemoteChanges)
end

function Module.EP_GetSaveData(EP: EasyProfile)
	return EP.ELS.SaveData
end

-- Returns the profile it was loaded, otherwise nil.
function Module.EP_YieldUntilLoaded(EP: EasyProfile): EasyProfile?
	if EP.IsActive and not EP.IsLoaded then
		EP.LoadYieldThreads[#EP.LoadYieldThreads+1] = coroutine.running()
		coroutine.yield()
	end
	return if EP.IsLoaded then EP else nil
end

function Module.EP_EndSession(EP: EasyProfile)
	if EP.IsActive then
		EP.IsActive = false
		
		local ELS = EP.ELS
		local Index = table.find(ELS.EPs, EP)
		if Index then
			table.remove(ELS.EPs, Index)
		end
		if not ELS.EPs[1] then
			Module.LS_MarkShouldRelease(ELS)
		end
		
		if EP.IsLoaded then
			EasyLifecycleSingle(EP, "replaced", "r_released")
		end
		EasyLifecycleSingle(EP, "destroyed", "none")
	end
end

-- Note: Prior to acquiring a session lock, save data will never be saved.
-- So these save functions will have no meaningful consequence.
function Module.EP_MarkShouldSave(EP: EasyProfile)
	Module.LS_MarkShouldSave(EP.ELS)
end
function Module.EP_MarkForceSave(EP: EasyProfile)
	Module.LS_MarkForceSave(EP.ELS)
end

function Module.EP_WhenChangesSaved(
	EP: EasyProfile,
	Callback: (thread | (Saved: boolean, EP: EasyProfile, UserData: any)->())?,
	UserData: any?
): SavedConnection
	
	local SC = {} :: SavedConnection

	SC.LS = EP.ELS
	SC.ChangeId = EP.ELS.ChangeId_Pending
	SC.DebugTraceback = debug.traceback(nil, 2)
	
	local WrappedCallback: (thread | (Saved: boolean, LS: LockerState, UserData: any)->())? = nil
	if type(Callback) == "function" then
		WrappedCallback = function(Saved, LS, ...)
			return Callback(Saved, EP, ...)
		end
	elseif type(Callback) == "thread" then
		WrappedCallback = Callback
	end
	
	SC.Callback = WrappedCallback
	SC.UserData = UserData
	
	-- Callback is deferred so that calling code does not break if the
	-- callback is executed immediately (e.g. before cleanup code has been
	-- set up). This works even if Callback == coroutine.running()!
	
	local LS = EP.ELS
	
	if not EP.IsActive or LS.IsRemoved then
		SC.Saved = false
		SC.Connected = false
		
		if SC.Callback then
			task.defer(SC.Callback, SC.Saved, SC.LS, SC.UserData)
		end
		
	elseif LS.ChangeId_Pending <= LS.ChangeId_Saved then
		SC.Saved = true
		SC.Connected = false
		
		if SC.Callback then
			task.defer(SC.Callback, SC.Saved, SC.LS, SC.UserData)
		end
		
	else
		SC.Saved = false
		SC.Connected = true
		
		LS.SavedConnections[#LS.SavedConnections+1] = SC
	end
	
	SC.Trigger = Module.SC_Trigger
	SC.Destroy = Module.SC_Destroy
	SC.Disconnect = Module.SC_Destroy
	
	return SC
end

function Module.EP_YieldUntilChangesSaved(EP: EasyProfile): boolean
	local Saved
	if not EP.IsActive then
		Saved = false
	else
		Saved = Module.LS_YieldUntilChangesSaved(EP.ELS)
	end
	return Saved
end

function Module.EP_ProductCreditQuery(
	EP: EasyProfile,
	ProductId: number
): number
	return Module.LS_ProductCreditQuery(EP.ELS, ProductId)
end

function Module.EP_ProductCreditGive(
	EP: EasyProfile,
	ProductId: number,
	Amount: number,
	UserData: any
)
	return Module.LS_ProductCreditGive(EP.ELS, ProductId, Amount, UserData)
end

function Module.EP_ProductCreditUse(
	EP: EasyProfile,
	ProductId: number,
	Amount: number,
	UserData: any
): boolean
	return Module.LS_ProductCreditUse(EP.ELS, ProductId, Amount, UserData)
end


function Module.EP_CallWhenProductIsProcessedAndSaved(
	EP: EasyProfile,
	PF: ProductProcessFunction,
	ReceiptInfo: ReceiptInfo,
	Callback: (IsPurchaseGranted: boolean)->()
)
	Module.PP_CallWhenProductIsProcessedAndSaved(
		State.PP, EP.ELS, PF, ReceiptInfo, Callback)
end

function Module.EP_YieldUntilProductIsProcessedAndSaved(
	EP: EasyProfile,
	PF: ProductProcessFunction,
	ReceiptInfo: ReceiptInfo
)
	return Module.PP_YieldUntilProductIsProcessedAndSaved(
		State.PP, EP.ELS, PF, ReceiptInfo)
end

return Module