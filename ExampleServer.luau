--!strict

local SessionLocker = require(game.ServerScriptService.SessionLocker)
local ExampleMigrators = require(game.ServerScriptService.ExampleMigrators)
local DataStoreService = require(game.ServerScriptService.DataStoreService)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")

local IsStudio = RunService:IsStudio()
local IsPrivateServer = game.PrivateServerId ~= ""

local State = {
	-- Only players that are still in the game will be present here. As soon as
	-- they leave they will be removed.
	PlayerState_ByPlayer = {} :: {[Player]: PlayerState};
	
	-- PlayerStates which are still being saved etc. will be present here even if
	-- the original players have left the game.
	PlayerState_ByUserId = {} :: {[number]: PlayerState};
	
	ServerClosing = false;
	LastHeartbeatNow = os.clock();
}

-- Session locker stuff
type SaveData = SessionLocker.SaveData & {
	ExampleMoney: number;
	ExamplePlaytime: number;
}
local LockerSpec: SessionLocker.LockerSpec = {
	DataStore = DataStoreService:GetDataStore("SaveData");
	SaveDataVersion = 1;
	SaveDataMigrators = ExampleMigrators.Migrators;
	SaveDataPatchers = ExampleMigrators.Patchers;
	SaveDataCreator = function(): SaveData
		return {
			Version = 1;
			VersionPatch = 0;
			Purchases = {};
			ProductCredit = {};
			
			ExampleMoney = 0;
			ExamplePlaytime = 0;
		};
	end;
	ProductCreditChanged = function(LS)
		local PS: PlayerState = (LS :: any).PS
		PS.Replicated.ProductCreditDirty = true
	end;
}

type PlayerState = {
	SessionLockerState: SessionLocker.LockerState;
	
	-- Independent of Player sessions.
	UserId: number;
	InfiniteProductCredit: boolean?;
	
	-- Reset with each new Player session.
	Player: Player;
	HasLeft: boolean;
	ClientReady: boolean; -- This will never be set to true for mocked players.
	
	Replicated: PS_Replicated;
}
type PS_Replicated = {
	ProductCreditDirty: boolean;
	LoadStatus: number?;
	LoadMinimumServerVersion: number?;
}

local function PlayerRemoving(Player)
	local PS = State.PlayerState_ByPlayer[Player]
	if PS then
		State.PlayerState_ByPlayer[Player] = nil
		assert(PS.Player == Player)
		
		PS.SessionLockerState:MarkShouldRelease()
		PS.HasLeft = true
	end
end
local function PlayerAdded(Player)
	
	-- Prevent players from joining when the server is shutting down.
	if State.ServerClosing then
		return
	end
	
	local UserId = Player.UserId
	
	-- Obtaining a PlayerState
	local PS: PlayerState
	local ExistingPS = State.PlayerState_ByUserId[UserId]
	if ExistingPS then
		if not ExistingPS.HasLeft then
			PlayerRemoving(ExistingPS.Player)
		end
		PS = ExistingPS
	else
		PS = {} :: PlayerState
		PS.UserId = UserId
		PS.SessionLockerState = SessionLocker.LockerCreatePlayer(
			LockerSpec, Player)
		do
			local LSAny = PS.SessionLockerState :: any
			LSAny.PS = PS
		end
		State.PlayerState_ByUserId[UserId] = PS
	end
	
	-- Session initialization.
	State.PlayerState_ByPlayer[Player] = PS
	PS.Player = Player
	PS.HasLeft = false
	PS.ClientReady = false
	PS.SessionLockerState:MarkShouldAcquire()
	
	PS.Replicated = {
		ProductCreditDirty = true;
	}
end
Players.PlayerRemoving:Connect(PlayerRemoving)
Players.PlayerAdded:Connect(PlayerAdded)
for _, Player in Players:GetPlayers() do
	task.spawn(PlayerAdded, Player)
end

RunService.Heartbeat:Connect(function()
	debug.profilebegin("L_ServerHeartbeat")
	
	local HeartbeatNow = os.clock()
	local ServerTimeNow = workspace:GetServerTimeNow()
	
	local HeartbeatDelta = HeartbeatNow - State.LastHeartbeatNow
	State.LastHeartbeatNow = HeartbeatNow
	
	for _, PS in State.PlayerState_ByPlayer do
		
		if PS.ClientReady then
			
			local R = PS.Replicated
			
			local LS = PS.SessionLockerState
			
			if R.ProductCreditDirty then
				R.ProductCreditDirty = false
				--[[
				Remotes.ProductCreditUpdated:FireClient(PS.Player,
					LS.SaveData.ProductCredit,
					if PS.InfiniteProductCredit then true else false)
				--]]
			end
			
			if R.LoadStatus ~= LS.LoadStatus or
				R.LoadMinimumServerVersion ~= LS.LoadMinimumServerVersion
			then
				R.LoadStatus = LS.LoadStatus
				R.LoadMinimumServerVersion = LS.LoadMinimumServerVersion
				--[[
				Remotes.LoadStatus:FireClient(PS.Player, LS.LoadStatus, LS.LoadMinimumServerVersion)
				--]]
			end
		end
	end
	
	for _, PS in State.PlayerState_ByUserId do
		if SessionLocker.UpdateEverything(PS.SessionLockerState, HeartbeatNow) then
			State.PlayerState_ByUserId[PS.UserId] = nil
		end
	end
	
	debug.profileend() -- L_ServerHeartbeat
end)

game:BindToClose(function()
	State.ServerClosing = true
	for _, PlayerState in State.PlayerState_ByPlayer do
		PlayerRemoving(PlayerState.Player)
	end
	while next(State.PlayerState_ByUserId) do
		task.wait()
	end
end)

-- This is typically a ModuleScript in ReplicatedStorage shared by server and client.
local Shared = {
	ProductId = {
		ExampleProduct = -1;	
	} :: {[string]: number};
}

local ProductProcessFunctions: {[number]: SessionLocker.ProductProcessFunction} = {
	[Shared.ProductId.ExampleProduct] = function(Op: number, LS: SessionLocker.LockerState)
		return true
	end;
}

MarketplaceService.ProcessReceipt = function(
	ReceiptInfo: SessionLocker.ReceiptInfo
): (Enum.ProductPurchaseDecision?)
	
	local Result = Enum.ProductPurchaseDecision.NotProcessedYet
	
	local PF = ProductProcessFunctions[ReceiptInfo.ProductId]
	if PF then
		
		local PS: PlayerState = State.PlayerState_ByUserId[ReceiptInfo.PlayerId]
		if not PS then
			-- Wait a frame for PlayerAdded signals to fire, just in case this 
			-- callback gets executed at the same moment when a player joins.
			-- I don't actually know if this is necessary, but for some reason
			-- I am superstitious about it... maybe due to the polling-based
			-- architecture.
			task.wait()
			PS = State.PlayerState_ByUserId[ReceiptInfo.PlayerId]
		end
		if PS then
			
			if SessionLocker.LS_YieldUntilProductIsProcessedAndSaved(
					PS.SessionLockerState, PF, ReceiptInfo)
			then
				Result = Enum.ProductPurchaseDecision.Granted
			end
		end
	end
	
	return Result
end

local function AttemptUseProductCredit(PS: PlayerState, ProductId: number, Count: number): boolean
	local UsedCredit = false
	if PS.InfiniteProductCredit then
		UsedCredit = true
	else
		UsedCredit = SessionLocker.LS_ProductCreditUse(
			PS.SessionLockerState, ProductId, Count)
	end
	return UsedCredit
end

local function RequestProductPurchase(Player: Player, ProductId: number)
	local PS = State.PlayerState_ByPlayer[Player]
	local ProcessFunction = ProductProcessFunctions[ProductId]
	if PS then
		local LS = PS.SessionLockerState
		if LS.LoadStatus == SessionLocker.LoadStatus.loaded and
			ProcessFunction and
			ProcessFunction(SessionLocker.ProductOp.validate, LS, ProductId)
		then
			if AttemptUseProductCredit(PS, ProductId, 1) then
				ProcessFunction(SessionLocker.ProductOp.apply, LS, ProductId)
			else
				MarketplaceService:PromptProductPurchase(Player, ProductId)
			end
		end
	end
end