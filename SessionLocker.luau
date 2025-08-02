--!strict

-- SessionLocker: DataStore session locking & save data management.
--
-- https://github.com/EmeraldSlash/SessionLocker
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 4 (2025-08-03)
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
-- Version 4:
--
-- >> Improved the easy API so that it works more like other session locking
-- libraries, and so that it now supports session reuse and save data versions
-- and migration.

local Module = {}

--
-- // API Summary
--
-- Types:
--
-- .LockerSpec (configuration table necessary for creating LockerStates)
-- .LockerState (active session locking & save data state associated with a UserId)
-- .SaveData (extend from this when creating your own save data type)
-- .SaveDataMigrator
-- .SaveDataPatcher
-- .ProductProcessFunction
-- .ReceiptInfo
--
-- Enums:
--
-- .ProductProcessOp
-- .LoadStatus
-- .RequestErrorKind
--
-- Global default configs & callbacks:
--
-- (These may also be defined in LockerSpecs, and the ones in LockerSpecs will
-- override these global ones.)
--
-- .Default_VerboseLogs
-- .Default_ReadOnlyDataStores
-- .Default_MaintainSessionPeriod
-- .Default_SessionExpiry
-- .Default_SessionRetryCooldown
-- .Default_PurchaseHistoryLimit
-- .Default_ReportDataStoreError()
-- .Default_SessionLockLost()
--
-- Functions:
--
-- .QueryConfig()
-- .TableDeepCopy()
-- .TableRestoreBackup()
-- .LogErrorVariations()
-- .LogPrefixCreate()
-- .GetRequestErrorKind()
-- .MarkShouldAcquire()
-- .MarkShouldRelease()
-- .MarkShouldSave()
-- .MarkForceSave()
-- .LockerResetSession()
-- .LockerCreate()
-- .LockerCreatePlayer()
-- .ProductCreditGive()
-- .ProductCreditQuery()
-- .ProductCreditUse()
-- .CallWhenProductIsProcessedAndSaved()
-- .YieldUntilProductIsProcessedAndSaved()
-- .UpdatePendingProductPurchases()
-- .UpdateSession() (returns true when session should be removed)
-- .UpdateEverything() (combines the above .Update*() functions)
--

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

	-- This function will be called when a session lock is lost.
	--
	-- This scenario should basically never happen. It will could happen if the
	-- current server stays alive but fails to maintain the session lock for 30
	-- minutes straight, and another server tries to obtain a session lock 30+
	-- minutes later. (30 minutes being the default SessionExpiry setting.)
	-- Another factor is that servers may have their timestamps be out of sync,
	-- in which case the actual time threshold for this happening is
	-- (SessionExpiry - TimestampDifference). If this happens to be less than
	-- MaintainSessionPeriod, then no server will be able to hold on to a session
	-- lock.
	--
	-- A default global function is defined for this callback, which will kick
	-- the player from the server if they are still in-game. If you don't want
	-- that you can just override the global function (to do nothing, or
	-- something else), or override the function in the LockerSpec here.
	--
	-- In any case, before this function is called, the LockerState's save data
	-- will be reset to default and its session will be reset. The session lock
	-- will be automatically reaquired later if possible.
	SessionLockLost: ((LS: LockerState)->())?;

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

	-- This function will be called when SaveData.ProductCredit is modified in
	-- any way.
	ProductCreditChanged: ((
		LS: LockerState,
		SD: any,
		ProductId: number,
		ChangeAmount: number,
		UserData: any
	)->())?;

	-- This function will be called when the LockerState.SaveData field is
	-- replaced by a new table, including when a session released or lost. This
	-- callback is useful if you keep external references to the SaveData table.
	--
	-- If you are using the SaveDataSaved callback, you should use this
	-- SaveDataReplaced callback as a way to detect a failure to save (e.g.
	-- because the session was released). All the ChangeIds in LockerState will
	-- have been reset to 0, so a correct response from your external code would
	-- be to discard all the ChangeIds it has and start again or cancel whatever
	-- it was trying to do.
	SaveDataReplaced: ((LS: LockerState, SD: any)->())?;

	-- This function will be called when SaveData is successfully saved to the
	-- DataStore. This can be used for anything that needs to keep track of
	-- whether data was saved or not: things like transactions betweens players
	-- (trading) or developer product processing (note: developer product
	-- saving is currently automatically handled by this library, so you
	-- shouldn't need to implement this).
	--
	-- The second argument is the ChangeId of the save, which is basically like a
	-- unique ID indicating the version of the save data. Calling
	-- .MarkShouldSave() or .MarkForceSave() will begin a save and return the
	-- current ChangeId of the SaveData (let's call this "ChangeId_Tracked"), so
	-- you can detect when a save is completed by seeing if ChangeId_Saved >=
	-- ChangeId_Tracked within this callback. If you are using this function then
	-- you should also probably be using the SaveDataReplaced callback above!
	SaveDataSaved: ((LS: LockerState, ChangeId_Saved: number)->())?;

	-- Use this to detect when the state of a session changes. Which is quite
	-- important for understanding how to interpret and interact with
	-- LockerState.SaveData, ChangeIds, and so on.
	LoadStatusChanged: ((LS: LockerState)->())?;

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
function Module.QueryConfig<T>(Config: T?, Default: T): T
	return if Config ~= nil then Config else Default
end

--
-- // Callback details
--
-- There are two important details about how callbacks are handled by this
-- module.
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
-- LockerState itself gets cleaned up by your code after .UpdateSession()
-- indicates the LockerState should be removed.
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
)
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

Module.RequestErrorKind = {
	-- Errors relating to our code (shouldn't retry, should log).
	script = 1;

	-- Errors that may be temporary or are unknown (should retry, but maybe not
	-- indefinitely, and should log).
	misc = 2;

	-- Errors relating to request limits or Roblox server issues (should retry
	-- indefinitely, and shouldn't log).
	backend = 3;
}

-- @UpdateAsyncTransformFunction Luau errors that occur inside an UpdateAsync
-- transform function will not throw an error on the calling thread. Instead,
-- the UpdateAsync will succeed, so the error will not be detectable by the
-- pcall(). Instead, you will need to manually detect such errors by having a
-- "transform success" variable (or equivalent) that gets set to "true" right
-- before returning from the transform function. This variable must also be
-- reset to "false" INSIDE the transform function every time it runs, because
-- the transform function may be called multiple times for a single call of
-- :UpdateAsync().

function Module.GetRequestErrorKind(PcallMessage: string): number
	local Result: number

	local DSE_S = Module.RequestErrorKind.script
	local DSE_B = Module.RequestErrorKind.backend
	local DSE_M = Module.RequestErrorKind.misc

	if PcallMessage then
		local ErrorCode = string.match(PcallMessage, "^(%d+):")
		if ErrorCode then
			local FirstChar = string.sub(ErrorCode, 1, 1)
			if FirstChar == "1" then
				Result = DSE_S
			elseif FirstChar == "3" then
				Result = DSE_B
			elseif FirstChar == "4" then
				if ErrorCode == "404" then
					Result = DSE_M
				else
					Result = DSE_S
				end
			elseif FirstChar == "5" then
				local Lookup = {
					["501"] = DSE_M;
					["502"] = DSE_B;
					["503"] = DSE_M;
					["504"] = DSE_M;
					["505"] = DSE_M;
					["511"] = DSE_S;
					["512"] = DSE_S;
					["513"] = DSE_S;
					["514"] = DSE_S;
				}
				local Kind = Lookup[ErrorCode]
				if Kind then
					Result = Kind
				end
			end
		end
	end

	if not Result then
		Result = DSE_M
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

Module.Default_ReportDataStoreError = function(
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
	elseif Module.GetRequestErrorKind(ErrorMessage) < Module.RequestErrorKind.backend then

		local Filters = {}
		for _, UserId in LS.AssociatedUserIds do
			Filters[#Filters+1] = {tostring(UserId), "{userid}"}
		end
		Filters[#Filters+1] = {LS.DataStoreKey, "{datastorekey}"}
		warn("[SessionLocker]"..Module.GsubFilter(Message, Filters))
	end
end

Module.Default_SessionLockLost = function(
	LS: LockerState
)
	for _, UserId in LS.AssociatedUserIds do
		local Player = game.Players:GetPlayerByUserId(UserId)
		if Player then
			Player:Kick("Save data session lock has been lost. Please tell the developer.")
		end
	end
end

--
-- Types and stuff
--

Module.LoadStatus = {
	loading = 0;
	data_store_request_fail = 1;
	session_is_locked = 2;
	invalid_version = 3;
	loaded = 4;
}

local LoadStatus = Module.LoadStatus
local SessionRNG = Random.new()

export type SaveData = {
	-- These must not be modified within Migrators or by your own code!
	Version: number;
	VersionPatch: number;
	Session: SD_Session?;

	-- These may be modified within Migrators, but should not be modified
	-- directly by your own code.
	Purchases: {SD_Purchase};
	ProductCredit: {SD_ProductCredit};
}

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
	LoadStatus: number;
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
}

export type SessionState = {
	Session: SD_Session;
	AutosaveAt: number;
	SavingProductPurchases: {SS_SavingProductPurchase};
	SessionSaveState: SessionSaveState?;
}
export type SS_SavingProductPurchase = {
	PendingProductPurchase: PendingProductPurchase;
	ChangeId: number;
}

export type PendingProductPurchase = {
	ProcessFunction: ProductProcessFunction;
	ReceiptInfo: ReceiptInfo;
	Thread: thread | PPP_Callback;
}
export type PPP_Callback = (IsPurchaseGranted: boolean)->()
export type ReceiptInfo = {
	PurchaseId: string;
	PlayerId: number;
	ProductId: number;
	PlaceIdWherePurchased: number;
	CurrencySpent: number;
}

Module.ProductProcessOp = {
	validate = 1;
	apply = 2;
}
export type ProductProcessFunction = (
	Op: number,
	LS: LockerState,
	ProductId: number)
->(boolean)

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

	InUse: boolean;
	PendingProductPurchases: {PendingProductPurchase};

	-- Reset with each new session

	-- The save data is always present so that it can be used and modified even
	-- while the real save data is loading or has failed to load. Upon a
	-- successful load, any changes made to the offline save data body will be
	-- merged into the newly loaded body.
	SaveData: SaveData;

	-- Anything that modifies the save data should increment
	-- LockerState.ChangeId_Pending to inform the library that a change needs to
	-- be saved, and LockerSate.ChangeId_Saved indicates the highest ChangeId
	-- which has been written to DataStore. LockerState.ChangeId_PendingForce
	-- will force data to be saved immediately if it is higher than
	-- ChangeId_Saved.
	ChangeId_Pending: number;
	ChangeId_PendingForce: number;
	ChangeId_Saved: number;

	LoadStatus: number;
	-- You could use this value in combination with MemoryStores to teleport
	-- players to servers which a SaveData version of this value or higher, if
	-- a player's data fails to load due to it having an unknown version.
	LoadMinimumServerVersion: number?;
	SessionLoadState: SessionLoadState?;
	SessionState: SessionState?;
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

--
-- External API stuff (1)
--

-- LockerStates can be reused when a player leaves and rejoins the game. All you
-- need to do is make sure your code keeps track of LockerStates in a way that
-- is independent of Player instances (e.g. track them by UserId instead), then
-- call these functions.
function Module.MarkShouldAcquire(LS: LockerState)
	LS.InUse = true
end
function Module.MarkShouldRelease(LS: LockerState)
	LS.InUse = false
end

-- Both of these functions return the ChangeId of this save operation, so you
-- can know when it finishes.
function Module.MarkShouldSave(LS: LockerState): number
	-- Indicate that data should save on the next autosave. This doesn't have any
	-- effect on data saving at the moment, as autosaves will always be
	-- performed in order to maintain the session lock.
	LS.ChangeId_Pending += 1
	return LS.ChangeId_Pending
end
function Module.MarkForceSave(LS: LockerState): number
	-- Indicate that data should be saved immediately.
	LS.ChangeId_Pending += 1
	LS.ChangeId_PendingForce = LS.ChangeId_Pending
	return LS.ChangeId_Pending
end

function Module.SessionReset(LS: LockerState)
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

		-- Any purchases which have not been saved will be made pending again.
		for _, SPP in SS.SavingProductPurchases do
			table.insert(LS.PendingProductPurchases, SPP.PendingProductPurchase)
		end
		table.clear(SS.SavingProductPurchases)
	end

	local Changed = LS.LoadStatus ~= LoadStatus.loading
	LS.LoadStatus = LoadStatus.loading
	LS.LoadMinimumServerVersion = nil
	LS.ChangeId_Pending = 0
	LS.ChangeId_PendingForce = 0
	LS.ChangeId_Saved = 0

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

	if LS.LockerSpec.SaveDataReplaced then
		LS.LockerSpec.SaveDataReplaced(LS, LS.SaveData)
	end
	if Changed and
		LS.LockerSpec.LoadStatusChanged
	then
		LS.LockerSpec.LoadStatusChanged(LS)
	end
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
	LS.InUse = false
	LS.PendingProductPurchases = {}
	Module.SessionReset(LS)
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

function Module.ProductCreditGive(
	LS: LockerState,
	SD: SaveData,
	ProductId: number,
	Amount: number,
	UserData: any
)
	local Array = SD.ProductCredit
	if Amount ~= 0 then
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

function Module.ProductCreditQuery(
	LS: LockerState,
	ProductId: number
): number
	local Credit = 0
	local ProductCredit = LS.SaveData.ProductCredit
	for ProductIndex, Product in ProductCredit do
		if Product[1] == ProductId then
			Credit = Product[2]
			break
		end
	end
	return Credit
end

function Module.ProductCreditUse(
	LS: LockerState,
	ProductId: number,
	Amount: number,
	UserData: any
): boolean

	local UsedCredit = false
	local ProductCredit = LS.SaveData.ProductCredit
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
	return UsedCredit
end

function Module.CallWhenProductIsProcessedAndSaved(
	LS: LockerState,
	PF: ProductProcessFunction,
	ReceiptInfo: ReceiptInfo,
	Callback: ()->()
)
	LS.PendingProductPurchases[#LS.PendingProductPurchases+1] = {
		ProcessFunction = PF;
		ReceiptInfo = ReceiptInfo;
		Thread = Callback;
	}
end

function Module.YieldUntilProductIsProcessedAndSaved(
	LS: LockerState,
	PF: ProductProcessFunction,
	ReceiptInfo: ReceiptInfo
)
	LS.PendingProductPurchases[#LS.PendingProductPurchases+1] = {
		ProcessFunction = PF;
		ReceiptInfo = ReceiptInfo;
		Thread = coroutine.running();
	}
	local IsPurchaseGranted = coroutine.yield()
	return IsPurchaseGranted
end

--
-- Internal stuff (2)
--

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
		Result.LoadStatus = LoadStatus.loaded

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
				NewResult.LoadStatus = LoadStatus.loaded

			else
				if (RemoteSD.Session) and
					(not SessionExpired(RemoteSD.Session, LSpec))
				then
					NewResult.LoadStatus = LoadStatus.session_is_locked

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
						NewResult.LoadStatus = LoadStatus.invalid_version
						NewResult.MinimumServerVersion = MinimumServerVersion

					else
						NewResult.SaveData = RemoteSD
						NewResult.SaveData.Session = SessionCreate()
						NewResult.LoadStatus = LoadStatus.loaded
					end
				end
			end

			TransformedResult = NewResult

			if (NewResult.LoadStatus == LoadStatus.loaded) and
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
			Result.LoadStatus = LoadStatus.data_store_request_fail

			if LSpec.ReportDataStoreError then
				LSpec.ReportDataStoreError(
					LS, "UpdateAsync_Load", RequestMessage)
			end

		elseif not TransformedResult then
			Result.LoadStatus = LoadStatus.data_store_request_fail

		else
			Result.LoadStatus = TransformedResult.LoadStatus
			Result.MinimumServerVersion = TransformedResult.MinimumServerVersion

			-- If saving is not enabled (i.e. the UpdateAsync transform function
			-- returned nil, cancelling the update) then the data won't have been
			-- returned by UpdateAsync, so we need to manually set it here.
			if (TransformedResult.LoadStatus == LoadStatus.loaded) and
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
			if Result.LoadStatus == LoadStatus.invalid_version then
				SLS.NextAttemptAt = math.huge
				LS.LoadMinimumServerVersion = Result.MinimumServerVersion
				if Changed and
					LSpec.LoadStatusChanged
				then
					LSpec.LoadStatusChanged(LS)
				end

			-- If the load failed for a different reason then we just keep
			-- retrying.
			elseif Result.LoadStatus ~= LoadStatus.loaded then
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
					SaveData = SD;
					AutosaveAt = HeartbeatNow + Module.QueryConfig(
						LSpec.MaintainSessionPeriod, Module.Default_MaintainSessionPeriod);
					SavingProductPurchases = {};
				}
				LS.SessionState = SS

				-- Merge local changes into the new save data table.
				if LSpec.MergeOfflineSaveDataWithLoadedSaveData then
					LSpec.MergeOfflineSaveDataWithLoadedSaveData(
						LS, LS.SaveData, SD)
				end

				LS.SaveData = SD
				LS.SessionLoadState = nil

				if LSpec.SaveDataReplaced then
					LSpec.SaveDataReplaced(LS, LS.SaveData)
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
		}
	else

		-- See @UpdateAsyncTransformFunction
		local TransformSuccess = false
		local TransformChangeId: number = nil
		local TransformSessionReleased: boolean = nil
		local TransformSessionAt: number = nil

		local function TransformFunction(RemoteSD): (SaveData?, {number}?)
			TransformSuccess = false

			local ChangeId = LS.ChangeId_Pending

			-- TransformSD should be suitable to completely overwrite RemoteSD,
			-- except for remote changes which will get moved into TransformSD.
			local TransformSD = Module.TableDeepCopy(LS.SaveData)

			TransformChangeId = ChangeId
			TransformSessionReleased = SSS.ShouldReleaseSession

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
				Module.SessionReset(LS)

				if LSpec.SessionLockLost then
					LSpec.SessionLockLost(LS)
				end

				break

			else
				assert(Result.ChangeId)

				-- Update the highest saved ChangeId.
				LS.ChangeId_Saved = Result.ChangeId
				if LS.LockerSpec.SaveDataSaved then
					LS.LockerSpec.SaveDataSaved(LS, LS.ChangeId_Saved)
				end

				-- Successful product purchases need to be completed here, before
				-- we release the session.
				local PPPThreads: {thread | PPP_Callback} = {}
				for Index = #SS.SavingProductPurchases, 1, -1 do
					local SPP = SS.SavingProductPurchases[Index]
					if SPP.ChangeId <= LS.ChangeId_Pending and
						SPP.ChangeId <= LS.ChangeId_Saved
					then
						table.remove(SS.SavingProductPurchases, Index)
						PPPThreads[#PPPThreads+1] = SPP.PendingProductPurchase.Thread
					end
				end
				for _, Thread in PPPThreads do
					task.spawn(Thread, true)
				end

				if Result.SessionReleased then
					Module.SessionReset(LS)
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

function Module.UpdatePendingProductPurchases(LS: LockerState, HeartbeatNow)

	local SS: SessionState? = LS.SessionState
	if SS and LS.LoadStatus == LoadStatus.loaded then

		--
		-- Apply all changes from pending product purchases to save data.
		--
		local PPPThreads = {}

		for _, PPP in LS.PendingProductPurchases do
			local ProductId = PPP.ReceiptInfo.ProductId
			local PurchaseId = PPP.ReceiptInfo.PurchaseId
			local SD = LS.SaveData

			-- If the product has already been purchased then we just
			-- immediately resume the purchase thread.
			local AlreadyProcessed = false
			for _, Purchase in SD.Purchases do
				if Purchase[1] == ProductId and
					Purchase[2] == PurchaseId
				then
					AlreadyProcessed = true
					break
				end
			end
			if AlreadyProcessed then
				PPPThreads[#PPPThreads+1] = PPP.Thread

			-- Otherwise, attempt to apply the product, then save.
			else

				-- Attempt to apply the product. And if product application
				-- fails, give the player credit for this product so they can
				-- use it for free sometime.
				if not PPP.ProcessFunction(Module.ProductProcessOp.apply, LS, ProductId) then
					Module.ProductCreditGive(LS, SD, ProductId, 1)
				end

				LS.ChangeId_Pending += 1
				LS.ChangeId_PendingForce = LS.ChangeId_Pending

				-- Add the product to purchase history.
				local Limit = Module.QueryConfig(
					LS.LockerSpec.PurchaseHistoryLimit,
					Module.Default_PurchaseHistoryLimit)
				if SD.Purchases[Limit] then
					table.remove(SD.Purchases, 1)
				end
				SD.Purchases[#SD.Purchases+1] = {ProductId, PurchaseId, os.time()}

				-- Wait for the change ID to be saved.
				table.insert(SS.SavingProductPurchases, {
					PendingProductPurchase = PPP;
					ChangeId = LS.ChangeId_Pending;
				})
			end
		end
		table.clear(LS.PendingProductPurchases)

		for _, Thread in PPPThreads do
			task.spawn(Thread, true)
		end
	end
end

function Module.UpdateSession(LS: LockerState, HeartbeatNow: number): boolean
	local ShouldRemove = false

	-- If we don't have session then we are either trying to load data or the
	-- player has left the game.
	local SS = LS.SessionState
	if not SS then

		-- Since the player is in-game, kick off the load job if the player has
		-- been marked as being ready for save data.
		if LS.InUse then
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

			-- Inform all pending product purchases that the purchase has failed.
			local PPPs = table.clone(LS.PendingProductPurchases)
			table.clear(LS.PendingProductPurchases)
			for _, PPP in PPPs do
				task.spawn(PPP.Thread, false)
			end
		end

	-- If we get here then the player is still in the game and is playing
	-- normally.
	elseif LS.InUse then
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

function Module.UpdateEverything(LS: LockerState, HeartbeatNow: number): boolean
	Module.UpdatePendingProductPurchases(LS, HeartbeatNow)
	return Module.UpdateSession(LS, HeartbeatNow)
end

--
-- Helper utility for building migrators
--

export type MigratorBuilder = {
	-- Internal fields
	MaxVersion: number;
	Migrators: {[number]: SaveDataMigrator};
	Patchers: {[number]: SaveDataPatcher};

	-- Exposed methods
	AddMigrator: (MB: MigratorBuilder, From: number, Migrator: SaveDataMigrator, Patcher: SaveDataPatcher?)->();
	AddPatcher: (MB: MigratorBuilder, For: number, Patcher: SaveDataPatcher)->();
	Build: (MB: MigratorBuilder)->({[number]: SaveDataMigrator}, {[number]: SaveDataPatcher});
}
function Module.MB_Create(): MigratorBuilder
	return {
		MaxVersion = -math.huge;
		Migrators = {};
		Patchers = {};

		AddMigrator = Module.MB_AddMigrator;
		AddPatcher = Module.MB_AddPatcher;
		Build = Module.MB_Build;
	} :: MigratorBuilder
end
function Module.MB_AddMigrator(
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
		Module.MB_AddPatcher(MB, FromVersion+1, Patcher)
	end
end
function Module.MB_AddPatcher(MB: MigratorBuilder, ForVersion: number, Patcher: SaveDataPatcher)
	if MB.Patchers[ForVersion] then
		error(("MB_AddPatcher: Patcher for version %d already exists!"):format(ForVersion))
	end
	MB.Patchers[ForVersion] = Patcher
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
-- .EasyStoreCreate(DataStore, CreateSaveDataFunction): EasyStore
--
-- type EasyStore
-- EasyStop:StartSession(DataStoreKey): EasyProfile
-- EasyStop:StartSessionReusable(DataStoreKey): EasyProfile
--
-- type EasyProfile
-- EasyProfile.IsLoaded: boolean
-- |
-- EasyProfile.Replaced: Signal
-- EasyProfile.Reset: Signal
-- EasyProfile.Loaded: Signal
-- EasyProfile.Saved: Signal
-- |
-- EasyProfile:GetSaveData(): SaveData
-- EasyProfile:ForceSave(): ChangeId
-- EasyProfile:YieldUntilSavedOrEnded(ChangeId): (WasSaved: boolean)
-- EasyProfile:YieldUntilLoadedOrEnded(): (ProfileIfLoaded: EasyProfile?)
--

export type EasyStore = {
	DataStore: DataStore;
	LSpec: LockerSpec;
	ELSs_ByKey: {[string]: {EasyLockerState}};

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
}

export type EasyProfile = {
	--
	-- Fields
	--

	ES: EasyStore;
	ELS: EasyLockerState;

	LoadYieldThreads: {thread};
	SaveYieldThreads: {{ChangeId: number, Thread: thread}};
	Bindables: {[string]: BindableEvent};

	IsActive: boolean;
	IsLoaded: boolean;

	--
	-- Signals
	--

	-- .SaveData has been replaced by a new table. First parameter if set to true
	-- indicates that the save data is loaded, otherwise it indicates it was
	-- reset.
	Replaced: RBXScriptSignal;

	-- .SaveData has been replaced by a new table (it has been reset to the
	-- default save data).
	Reset: RBXScriptSignal;

	-- .SaveData has been replaced by a new table (that is the fully loaded and
	-- migrated save data).
	Loaded: RBXScriptSignal;

	-- .SaveData has been saved.
	Saved: RBXScriptSignal;

	--
	-- Methods
	--

	GetSaveData: (EP: EasyProfile)->(SaveData);
	ForceSave: (EP: EasyProfile)->(number);
	EndSession: (EP: EasyProfile)->();
	YieldUntilLoadedOrEnded: (EP: EasyProfile)->(EasyProfile?);
	YieldUntilSavedOrEnded: (EP: EasyProfile, ChangeId: number)->(boolean);
}

export type EasyLockerState = LockerState & {
	EPs: {EasyProfile};
}

local State = (function() return { -- Seal the table

	ES_ByDataStore = {} :: {[DataStore]: EasyStore};
	ConnectionHeartbeat = nil :: RBXScriptConnection?;

} end)()

local function EasyHeartbeat()
	debug.profilebegin("SessionLocker_EasyHeartbeat")
	if State.ConnectionHeartbeat then
		local HeartbeatNow = os.clock()
		for _, ES in State.ES_ByDataStore do
			for Key, ELSs in ES.ELSs_ByKey do
				local Remove = {}
				for Index, ELS in ELSs do
					if Module.UpdateEverything(ELS, HeartbeatNow) then
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
		end
		if not next(State.ES_ByDataStore) then
			State.ConnectionHeartbeat:Disconnect()
			State.ConnectionHeartbeat = nil
		end
	end
	debug.profileend()
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
	Patchers: {[number]: SaveDataPatcher}?

): EasyStore

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
			LoadStatusChanged = function(LS)
				local ELS: EasyLockerState = LS :: any
				if ELS.EPs then
					for _, EP in ELS.EPs do

						local IsLoaded =
							if ELS.LoadStatus == LoadStatus.loaded then true else false
						if EP.IsLoaded ~= IsLoaded then
							EP.IsLoaded = IsLoaded

							if not IsLoaded then
								EP.Bindables.Reset:Fire()
								EP.Bindables.Replaced:Fire()

							else
								EP.Bindables.Loaded:Fire()
								EP.Bindables.Replaced:Fire()

								for _, Thread in EP.LoadYieldThreads do
									task.defer(Thread)
								end
								table.clear(EP.LoadYieldThreads)
							end
						end
					end
				end
			end;
			SaveDataReplaced = function(LS)
				local ELS: EasyLockerState = LS :: any
				if ELS.EPs then
					for _, EP in ELS.EPs do
						for _, Group in EP.SaveYieldThreads do
							task.defer(Group.Thread)
						end
						table.clear(EP.SaveYieldThreads)
					end
				end
			end,
			SaveDataSaved = function(LS)
				local ELS: EasyLockerState = LS :: any
				if ELS.EPs then
					for _, EP in ELS.EPs do
						EP.Bindables.Saved:Fire()

						for Index = #EP.SaveYieldThreads, 1, -1 do
							local Group = EP.SaveYieldThreads[Index]
							if Group.ChangeId <= LS.ChangeId_Saved then
								task.defer(Group.Thread, LS.ChangeId_Saved)
								table.remove(EP.SaveYieldThreads, Index)
							end
						end
					end
				end
			end;
			ProductCreditChanged = function(LS)
				local ELS: EasyLockerState = LS :: any
				if ELS.EPs then
					for _, EP in ELS.EPs do
						EP.Bindables.ProductCreditChanged:Fire()
					end
				end
			end;
		}

		local ES: EasyStore = {
			DataStore = DataStore;
			LSpec = LSpec;
			ELSs_ByKey = {};

			StartSession = Module.ES_StartSession;
			StartSessionReusable = Module.ES_StartSessionReusable;
		}
		State.ES_ByDataStore[ES.DataStore] = ES

		if not State.ConnectionHeartbeat then
			State.ConnectionHeartbeat =
				game:GetService("RunService").Heartbeat:Connect(EasyHeartbeat)
		end
	end

	return State.ES_ByDataStore[DataStore]
end

function Module.EP_GetSaveData(EP: EasyProfile)
	return EP.ELS.SaveData
end

-- Note: Prior to acquiring a session lock, save data will never be saved.
function Module.EP_ForceSave(EP: EasyProfile)
	local ChangeId = Module.MarkForceSave(EP.ELS)
	return ChangeId
end

function Module.EP_EndSession(EP: EasyProfile)
	if EP.IsActive then
		EP.IsActive = false
		EP.IsLoaded = false

		local ELS = EP.ELS
		local Index = table.find(ELS.EPs, EP)
		if Index then
			table.remove(ELS.EPs, Index)
		end
		if not ELS.EPs[1] then
			Module.MarkShouldRelease(ELS)
		end

		for _, Thread in EP.LoadYieldThreads do
			task.defer(Thread)
		end
		table.clear(EP.LoadYieldThreads)
		for _, Group in EP.SaveYieldThreads do
			task.defer(Group.Thread)
		end
		table.clear(EP.SaveYieldThreads)
	end
end

-- Returns the profile it was loaded, otherwise nil.
function Module.EP_YieldUntilLoadedOrEnded(EP: EasyProfile): EasyProfile?
	if EP.IsActive and not EP.IsLoaded then
		EP.LoadYieldThreads[#EP.LoadYieldThreads+1] = coroutine.running()
		coroutine.yield()
	end
	return if EP.IsLoaded then EP else nil
end

-- Returns true if saved, otherwise nil.
function Module.EP_YieldUntilSavedOrEnded(EP: EasyProfile, ChangeId: number): boolean
	local Saved = false
	if EP.IsActive and EP.IsLoaded then
		if EP.ELS.ChangeId_Saved >= ChangeId then
			Saved = true
		else
			EP.SaveYieldThreads[#EP.SaveYieldThreads+1] = {
				ChangeId = ChangeId,
				Thread = coroutine.running()
			}
			local ChangeId_Saved = coroutine.yield()
			if ChangeId_Saved and ChangeId_Saved >= ChangeId then
				Saved = true
			end
		end
	end
	return false
end

local function EP_Init(EP: EasyProfile)
	EP.IsActive = true
	EP.IsLoaded = false
	EP.LoadYieldThreads = {}
	EP.SaveYieldThreads = {}

	local Bindables = (function() return { -- Seal the table

		Replaced = Instance.new("BindableEvent");
		Reset = Instance.new("BindableEvent");
		Loaded = Instance.new("BindableEvent");
		Saved = Instance.new("BindableEvent");
		ProductCreditChanged = Instance.new("BindableEvent");

	} end)()
	EP.Bindables = Bindables
	EP.Reset = Bindables.Reset.Event
	EP.Loaded = Bindables.Loaded.Event
	EP.Saved = Bindables.Saved.Event

	EP.GetSaveData = Module.EP_GetSaveData
	EP.ForceSave = Module.EP_ForceSave
	EP.EndSession = Module.EP_EndSession
	EP.YieldUntilLoadedOrEnded = Module.EP_YieldUntilLoadedOrEnded
	EP.YieldUntilSavedOrEnded = Module.EP_YieldUntilSavedOrEnded
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
	Module.MarkShouldAcquire(EP.ELS)

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
						(ELS.LoadStatus == LoadStatus.loaded) and
						(Found.LoadStatus ~= LoadStatus.loaded)
					)
				then
					Found = ELS
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
	Module.MarkShouldAcquire(EP.ELS)

	return EP
end

return Module