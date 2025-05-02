--!strict

-- SessionLocker - DataStore session locking & common save data operations
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 1 (2025-05-02)
--

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
--
-- Global default functions & configs:
--
-- (These may also be defined in LockerSpecs, and the ones in LockerSpecs will
-- override these global ones.)
--
-- .Default_ReportDataStoreError()
-- .Default_HandleSessionLockLost()
-- .Default_SavingEnabled
-- .Default_VerboseLogs
-- .Default_MaintainSessionPeriod
-- .Default_SessionExpiry
-- .Default_SessionRetryCooldown
-- .Default_PurchaseHistoryLimit
--
-- Functions:
--
-- .TableDeepCopy()
-- .LogPrefixCreate()
-- .MarkShouldAcquire()
-- .MarkShouldRelease()
-- .MarkShouldSave()
-- .SessionReset()
-- .SessionCreate()
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
	
	--
	-- SaveDataVersion
	--
	-- Must start at 1, and increment by 1 with every version change. Needs to
	-- be directly used as an index into an array of Migrators.
	--
	-- This field will place a hard limit on whether a player's save data can be 
	-- used or not. If a player joins a server with a version that the server 
	-- doesn't know about then the player will be put into the safe mode where no 
	-- data can be loaded or saved at all. (In this scenario the module stores and 
	-- exposes what version was loaded, so that you can use that information to 
	-- respond appropriately e.g. find new servers which are >= that version to 
	-- teleport players to.)
	
	SaveDataVersion: number;
	
	-- [SaveDataVersion]: PatcherOrMigrator
	SaveDataMigrators: {[number]: SaveDataMigrator};
	SaveDataPatchers: {[number]: SaveDataPatcher};
	
	-- Creates new save data when needed. Must not yield, as it can be called
	-- from within UpdateAsync transform functions.
	SaveDataCreator: (()->(any));
	
	--
	-- Optional parameters
	--
	-- If an optional function is not provided then nothing will be done. Some 
	-- functions have a default version Module.Default_* which you can have a 
	-- look at.
	--
	
	ReportDataStoreError: ((
		ErrorMessage: string,
		DataStore: DataStore,
		OperationName: string,
		UserId: number,
		DataStoreKey: string
	)->())?;
	
	-- What do you want to do when session lock is lost? This could happen if the
	-- current server fails to maintain the session lock, and another server 
	-- tries to obtain a session lock 30+ minutes later. By default in this 
	-- situation we kick the player. In any case, their current save file has 
	-- been reset to default (as if they had rejoined the server), and the 
	-- session will be restarted automatically if the player is still in the 
	-- server.
	HandleSessionLockLost: ((LS: LockerState)->())?;
	
	-- Use this function if you want to merge the local copy of save data 
	-- (SourceSD) into the newly loaded save data (DestSD). This local copy is 
	-- guaranteed to never have been saved before, it's completely fresh dummy 
	-- data that the player was using before the real data loaded. Only some 
	-- values may be mergable: for example, if you track a player's playtime, you
	-- could do DestSD.TimePlayedSeconds += SourceSD.TimePlayerSeconds.
	MergeOfflineSaveDataWithLoadedSaveData: ((
		LS: LockerState,
		SourceSD: any,
		DestSD: any
	)->())?;
	
	ProductCreditChanged: ((
		LS: LockerState,
		SD: any,
		ProductId: number,
		ChangeAmount: number,
		UserData: any
	)->())?;
	
	SaveDataReplaced: ((LS: LockerState, SD: any)->())?;
	
	-- Use this to detect when save data loads or is reset or whatever.
	LoadStatusChanged: ((LS: LockerState)->())?;
	
	-- These are configuration values which you can change for this session spec 
	-- only. If a value is nil, then the corresponding Module.Default_* value 
	-- will be used instead.
	SavingEnabled: boolean?;
	VerboseLogs: boolean?;
	MaintainSessionPeriod: number?;
	SessionExpiry: number?;
	SessionRetryCooldown: number?;
	PurchaseHistoryLimit: number?;
}

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
-- Default options
--

Module.Default_ReportDataStoreError = function(
	ErrorMessage: string,
	DataStore: DataStore,
	OperationName: string,
	UserId: number,
	DataStoreKey: string
)
	warn(debug.traceback("[SessionLocker] "..tostring(ErrorMessage)))
end

Module.Default_HandleSessionLockLost = function(
	LS: LockerState
)
	local Player = game.Players:GetPlayerByUserId(LS.UserId)
	if Player then
		Player:Kick("Save data session lock has been lost. Please tell the developer.")
	end
end

-- If set to false, save data will be loaded but never be modified.
Module.Default_SavingEnabled = true

Module.Default_VerboseLogs = false

-- Maximum duration save data is allowed to go without saving to maintain the 
-- server's session lock.
Module.Default_MaintainSessionPeriod = 5*60

-- Other servers will be able to claim the session if the session lock is not 
-- updated for this period of time.
Module.Default_SessionExpiry = 30*60

-- How long to wait between failed header requests.
Module.Default_SessionRetryCooldown = 10

-- How many entries can be stored in purchase history before old purchases are
-- forgotten. Avoid changing this unnecessarily as it will affect save data.
Module.Default_PurchaseHistoryLimit = 100

--
-- Utilities
--

-- Use this for easily creating new save data from a template table.
function Module.TableDeepCopy<T>(Table: T): T
	
	local Result = {
		Table = (nil :: any) :: T;
	}
	
	-- Duplicate references to the same table are handled correctly by caching 
	-- all the new tables we create. We don't handle table keys though.
	local TableCache: {[any]: any} = {}
	TableCache[Table] = Result
	
	type Entry = {
		Source: {[any]: any};
		Parent: {[any]: any};
		Key: any;
	}
	local Stack: {Entry} = {{
		Source = Table :: any;
		Parent = Result :: any;
		Key = "Table";
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
	
	return Result.Table
end

-- Make a nice log prefix :)
function Module.LogPrefixCreate(
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
	
	UserId: number;
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
	
	ChangeId_Pending: number;
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

function Module.MarkShouldSave(LS: LockerState)
	LS.ChangeId_Pending += 1
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
	LS.ChangeId_Saved = 0
	
	-- Use default save data before anything has loaded.
	LS.SaveData = UseSaveDataCreator(LS.LockerSpec, LS.LogPrefix)
	
	if LS.LockerSpec.SaveDataReplaced then
		LS.LockerSpec.SaveDataReplaced(LS, LS.SaveData)
	end
	if Changed and
		LS.LockerSpec.LoadStatusChanged
	then
		LS.LockerSpec.LoadStatusChanged(LS)
	end
end

function Module.SessionCreate(
	LockerSpec: LockerSpec,
	UserId: number,
	
	-- The key save data is stored under.
	DataStoreKey: string?,
	
	-- The prefix used when outputting logs.
	LogPrefix: string?,
	
	-- Prevent DataStore requests from being made.
	DisableAPIs: boolean?
)
	local LS = {} :: LockerState
	LS.UserId = UserId
	LS.LockerSpec = LockerSpec
	LS.DataStoreKey = DataStoreKey or string.format("%i", UserId)
	LS.LogPrefix = LogPrefix or Module.LogPrefixCreate(UserId)
	LS.DisableAPIs = DisableAPIs
	LS.InUse = false
	LS.PendingProductPurchases = {}
	Module.SessionReset(LS)
	return LS
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

local function CheckValue<T>(A: T?, B: T)
	return if A ~= nil then A else B
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
		warn(("%s Invalid %s version (type is not 'number'). Version: '%s' (type '%s'), VersionPatch: '%s' (type '%s')."):format(
			LogPrefix,
			LogDataIdentifier,
			tostring(Data.Version),
			type(Data.Version),
			tostring(Data.VersionPatch),
			type(Data.VersionPatch)))
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
	
	local LockerSpec = LS.LockerSpec
	
	if LS.DisableAPIs then
		Result.SaveData = UseSaveDataCreator(LockerSpec, LS.LogPrefix)
		Result.SaveData.Session = SessionCreate()
		Result.LoadStatus = LoadStatus.loaded
		
	else
		
		local TransformedResult: SLS_Result? = nil

		local function TransformFunction(
			RemoteSD: SaveData?
		): (SaveData?, {number}?)
			
			TransformedResult = nil
			
			local NewResult = {} :: SLS_Result
			
			if not RemoteSD then
				NewResult.SaveData = UseSaveDataCreator(LockerSpec, LS.LogPrefix)
				NewResult.SaveData.Session = SessionCreate()
				NewResult.LoadStatus = LoadStatus.loaded
				
			else
				if (RemoteSD.Session) and
					(not SessionExpired(RemoteSD.Session, LockerSpec))
				then
					NewResult.LoadStatus = LoadStatus.session_is_locked
					
				else
					local MigrateSuccess, MinimumServerVersion = DoMigration(
						LS.LogPrefix,
						RemoteSD,
						"SaveData",
						LockerSpec.SaveDataVersion,
						LockerSpec.SaveDataMigrators,
						LockerSpec.SaveDataPatchers,
						CheckValue(LockerSpec.VerboseLogs, Module.Default_VerboseLogs))
					
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
				(CheckValue(LockerSpec.SavingEnabled, Module.Default_SavingEnabled))
			then
				-- Note: If saving is disabled then the code making the request cannot 
				-- rely on the returned Header having particular values set by the 
				-- request (e.g. the session value, or migrated data).
				return NewResult.SaveData, {LS.UserId}
			else
				return nil
			end
		end
		
		local RequestSuccess, RequestMessage = pcall(function()
			Result.SaveData = LockerSpec.DataStore:UpdateAsync(
				LS.DataStoreKey,
				TransformFunction)
		end)
		
		-- If request failed then we just do nothing except report the error if
		-- it's nontrivial.
		if not RequestSuccess then
			Result.LoadStatus = LoadStatus.data_store_request_fail
			
			if LockerSpec.ReportDataStoreError then
				LockerSpec.ReportDataStoreError(
					RequestMessage,
					LockerSpec.DataStore,
					"UpdateAsync_Load",
					LS.UserId,
					LS.DataStoreKey)
			end
		
		elseif not TransformedResult then
			Result.LoadStatus = LoadStatus.data_store_request_fail
		
		else
			Result.LoadStatus = TransformedResult.LoadStatus
			Result.MinimumServerVersion = TransformedResult.MinimumServerVersion
			
			-- If saving is not enabled (i.e. the UpdateAsync transform function 
			-- returned nil, cancelling the update) then the data won't have been 
			-- returned by UpdateAsync, so we need to manually set it here.
			if (not CheckValue(LockerSpec.SavingEnabled, Module.Default_SavingEnabled)) and
				(TransformedResult.LoadStatus == LoadStatus.loaded)
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
	local LockerSpec = LS.LockerSpec
	
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
					LockerSpec.LoadStatusChanged
				then
					LockerSpec.LoadStatusChanged(LS)
				end
				
			-- If the load failed for a different reason then we just keep 
			-- retrying.
			elseif Result.LoadStatus ~= LoadStatus.loaded then
				SLS.NextAttemptAt =
					HeartbeatNow +
					CheckValue(LockerSpec.SessionRetryCooldown, Module.Default_SessionRetryCooldown)
				if Changed and
					LockerSpec.LoadStatusChanged
				then
					LockerSpec.LoadStatusChanged(LS)
				end
			
			-- Otherwise if the load succeeded, we can be happy.
			else
				local SD = Result.SaveData
				assert(SD)
				assert(SD.Session)
				
				local SS: SessionState = {
					Session = SD.Session;
					SaveData = SD;
					AutosaveAt =
						HeartbeatNow +
						CheckValue(LockerSpec.MaintainSessionPeriod, Module.Default_MaintainSessionPeriod);
					SavingProductPurchases = {};
				}
				LS.SessionState = SS
				
				-- Merge local changes into the new save data table.
				if LockerSpec.MergeOfflineSaveDataWithLoadedSaveData then
					LockerSpec.MergeOfflineSaveDataWithLoadedSaveData(LS, LS.SaveData, SD)
				end
				
				LS.SaveData = SD
				LS.SessionLoadState = nil
				
				if LS.LockerSpec.SaveDataReplaced then
					LS.LockerSpec.SaveDataReplaced(LS, LS.SaveData)
				end
				if Changed and
					LockerSpec.LoadStatusChanged
				then
					LockerSpec.LoadStatusChanged(LS)
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
	local LockerSpec = LS.LockerSpec
	
	if LS.DisableAPIs then
		SSS.Result = {
			RequestSuccess = true;
			LostSessionLock = false;
			SessionReleased = SSS.ShouldReleaseSession;
			SessionAt = if SSS.ShouldReleaseSession then nil :: any else os.time();
			ChangeId = LS.ChangeId_Pending;
		}
	else
		
		local TransformSuccess = false
		local TransformChangeId: number = nil
		local TransformSessionReleased: boolean = nil
		local TransformSessionAt: number = nil
		
		local function TransformFunction(RemoteSD): (SaveData?, {number}?)
			TransformSuccess = false
			
			local ChangeId = LS.ChangeId_Pending
			
			-- TransformSD should be suitable to completely overwrite RemoteSD, 
			-- except for remote changes which will get moved into TransformSD.
			local TransformSD = UseSaveDataCreator(LockerSpec, LS.LogPrefix)
			
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
				return TransformSD, {LS.UserId}
			else
				return nil
			end
		end
		
		local NewPSD
		
		local RequestSuccess, RequestMessage = pcall(function()
			if CheckValue(LockerSpec.SavingEnabled, Module.Default_SavingEnabled) then
				NewPSD = LockerSpec.DataStore:UpdateAsync(
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
			
			if LockerSpec.ReportDataStoreError then
				LockerSpec.ReportDataStoreError(
					RequestMessage,
					LockerSpec.DataStore,
					"UpdateAsync_Save",
					LS.UserId,
					LS.DataStoreKey)
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
	local LockerSpec = LS.LockerSpec
	
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
				SSS.NextAttemptAt =
					HeartbeatNow +
					CheckValue(LockerSpec.SessionRetryCooldown, Module.Default_SessionRetryCooldown)
				
			elseif Result.LostSessionLock then
				warn(("%s Save data session lock has been lost.")
					:format(LS.LogPrefix))
				
				SS.SessionSaveState = nil
				Module.SessionReset(LS)
				
				if LockerSpec.HandleSessionLockLost then
					LockerSpec.HandleSessionLockLost(LS)
				end
				
				break
				
			else
				assert(Result.ChangeId)
				
				-- Update the highest saved ChangeId.
				LS.ChangeId_Saved = Result.ChangeId
				
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
					SS.AutosaveAt =
						HeartbeatNow +
						CheckValue(LockerSpec.MaintainSessionPeriod, Module.Default_MaintainSessionPeriod)
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
				
				-- Add the product to purchase history.
				local Limit = CheckValue(
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
				
				-- We want to force an autosave to begin immediately. This value 
				-- needs to be set to a valid time such that data will also be 
				-- saved along with the header.
				SS.AutosaveAt = HeartbeatNow
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
			LS, SS, HeartbeatNow, HeartbeatNow >= SS.AutosaveAt, false)
		
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

return Module