# SessionLocker

This is a reusable library for using DataStore session locking in Roblox. The system design been used in production code, but this particular library is currently untested as I have only just just extracted it out into a reusable library for use in an upcoming project.

At the moment, this library provides:
- DataStore session locking, including session reuse capabilities
- Save data migration & patching facilities
- Safe Developer Product processing, product credit, and product purchase history

Future plans:
- Add support for remote changes (operations that can be remotely applied to locked `DataStore` keys by other game servers)
- Further decouple the Developer Product stuff from the core library, and make its logic more generic so that similar operations can be performed by users of the library.
- Add some higher granularity usage options for session locking state machines so that if someone doesn't like one part of one particular state machine they can just rewrite it themselves and reuse the other state machines that they don't care about.
- Add some lower granularity usage options so that people who don't want to customize anything can just "plug & play", making like two function calls with barebones work and minimal typechecking to get themselves up and running.
- Add a low granularity API for waiting until a change has been saved. This API should be a dmeo of the deeper APIs, as this use case can already be achieved with the current API, but it's not good for beginners.

My approach to designing libraries is different from what most other people seem to do, so if that kind of thing interests you, go read the code. I have also provided some example files which are pretty helpful for understanding the library.

Some important things to note about the design of this library:
- The use of singletons or globals is avoided so that all important inputs can be configured by usage code and so that there are no stupid limitations (e.g. an extremely common limitation is that a library globally refers to `DataStoreService` so the DataStore API can't be mocked, and similarly the library only supports a single `DataStore` being used so if you need more then you have to duplicate the library or do it yourself).
- I don't like thread/coroutine stuff (or derived constructs, like Promises) because it's all just a complicated nightmare of code execution, especially for APIs which are very heavy on blocking such as `DataStore`s. So instead I've designed the library to work using explicit state machines that get re-evaluated every frame for every player. This is fine: there are no performance problems, despite what people may think. Blocking Roblox API calls are isolated so that they can behave as nice pure functions with no annoying code execution side effects.

For reading the code, I recommend a tab width of 3 since that's what I wrote it with (and my Luau formatting style depends on tab width). Unfortunately GitHub does not provide this tab widh as an option in their UI, but you can get it for a particular file by appending `?ts=3` to the end of the file's URL.

## Realistic Example

```luau
--!strict

local SessionLocker = require(game.ServerScriptService.SessionLocker)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")

type SaveData = SessionLocker.SaveData & {
	Gold: number;
	Playtime: number;
}

local LockerSpec: SessionLocker.LockerSpec = {
	DataStore = DataStoreService:GetDataStore("SaveData");

	SaveDataVersion = 2;
	SaveDataMigrators = {
		
		-- Playtime was added in version 2.
		[1] = function(SaveData)
			SaveData.Playtime = 0
			return 0
		end;
		
	};
	SaveDataPatchers = {};

	SaveDataCreator = function()
		return {
			Version = 1;
			VersionPatch = 0;
			Purchases = {};
			ProductCredit = {};
			
			-- Your custom stuff here!
			Gold = 0;
			Playtime = 0;
		}
	end;
}

local State = {
	Lockers = {} :: {[number]: SessionLocker.LockerState};
	ServerClosing = false;
}

game:BindToClose(function()
	State.ServerClosing = true
	while next(State.Lockers) do task.wait() end
end)

RunService.Heartbeat:Connect(function()
	local HeartbeatNow = os.clock()
	
	for UserId, Locker in State.Lockers do
		
		-- Let's give our player one playtime unit for every frame
		-- they spend in-game!
		if Locker.LoadStatus == SessionLocker.LoadStatus.loaded and Locker.InUse then
			local SaveData = Locker.SaveData :: SaveData
			SaveData.Playtime += 1
		end

		if SessionLocker.UpdateEverything(Locker, HeartbeatNow) then
			State.Lockers[UserId] = nil
		end
	end
end)

Players.PlayerAdded:Connect(function(Player)
	if not State.ServerClosing then
		if not State.Lockers[Player.UserId] then
			State.Lockers[Player.UserId] = SessionLocker.LockerCreate(
				LockerSpec, tostring(Player.UserId), {17614882})
		end
		local Locker = State.Lockers[Player.UserId]
		SessionLocker.MarkShouldAcquire(Locker)
	end
end)

Players.PlayerRemoving:Connect(function(Player)
	local Locker = State.Lockers[Player.UserId]
	if Locker then
		SessionLocker.MarkShouldRelease(Locker)
	end
end)

local ProductProcessFunctions: {[number]: SessionLocker.ProductProcessFunction} = {
	[12345678] = function(Op: number, Locker: SessionLocker.LockerState)
		if Op == SessionLocker.ProductProcessOp.apply then
			-- Give the player 10 gold when they purchase the product.
			local SaveData = Locker.SaveData :: SaveData
			SaveData.Gold += 10
		end
		return true
	end;
}

MarketplaceService.ProcessReceipt = function(
	ReceiptInfo: SessionLocker.ReceiptInfo
): (Enum.ProductPurchaseDecision?)
	
	local Result = Enum.ProductPurchaseDecision.NotProcessedYet
	
	local PF = ProductProcessFunctions[ReceiptInfo.ProductId]
	local Locker = State.Lockers[ReceiptInfo.PlayerId]
	if PF and Locker then

		if SessionLocker.YieldUntilProductIsProcessedAndSaved(
			Locker, PF, ReceiptInfo)
		then
			Result = Enum.ProductPurchaseDecision.Granted
		end
	end
	
	return Result
end
```
