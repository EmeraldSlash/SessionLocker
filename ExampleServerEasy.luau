--!strict

local Players = game:GetService("Players")
local DataStore = game:GetService("DataStoreService"):GetDataStore("Frogs")

local SessionLocker = require(script.Parent.SessionLocker)

type MySaveData = {
	Gold: number;
	Diamonds: number;
}
local function CreateMySaveData(): MySaveData
	return {
		Gold = 0;
		Diamonds = 0;
	}
end

local Migrators, Patchers
do
	local Builder = SessionLocker.MB_Create()
	
	-- Added the Diamonds field in version 2!
	Builder:AddMigrator(1, function(SaveData)
		SaveData.Diamonds = 0
		return 1
	end)
	
	Builder:AddPatcher(2, function(SaveData, Patch)
		
		-- In the first version of the migrator we gave people 1000 diamonds on 
		-- accident. Somebody pushed the testing code to prod.. Let's revert that 
		-- here :)
		if Patch == 0 then
			SaveData.Diamonds = math.max(SaveData.Diamonds-1000, 0)
		end
		
		return 1
	end)
	
	Migrators, Patchers = Builder:Build()
end

local Store = SessionLocker.EasyStoreCreate(
	DataStore, CreateMySaveData, 2, 1, Migrators, Patchers)
local Profile_ByPlayer = {}

local function PlayerAdded(Player)
	local Profile = Store:StartSession(tostring(Player.UserId))
	Profile_ByPlayer[Player] = Profile
	print("Started session")
	
	if not Profile:YieldUntilLoadedOrEnded() then
		warn("Failed to load session")
		
	else
		local SD: MySaveData = Profile:GetSaveData() :: any
		print(("Session loaded with gold %d"):format(SD.Gold))
		
		SD.Gold += 10
		
		print(("Forcing a save of gold %d"):format(SD.Gold))
		local ChangeId = Profile:ForceSave()
		
		print("Waiting until save is complete..")
		Profile:YieldUntilSavedOrEnded(ChangeId)
		
		print("Gold saved, ending session")
		Profile:EndSession()
		Profile_ByPlayer[Player] = nil
	end
end
local function PlayerRemoving(Player)
	local Profile = Profile_ByPlayer[Player]
	if Profile then
		print("Player left, ending session")
		Profile:EndSession()
		Profile_ByPlayer[Player] = nil
	end
end
Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(PlayerRemoving)
for _, Player in Players:GetPlayers() do
	task.spawn(PlayerAdded, Player)
end