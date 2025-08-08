--!strict

local DataStoreService = require(game.ServerScriptService.DataStoreService)

local SessionLocker = require(game.ReplicatedStorage.SessionLocker)

local Players = game:GetService("Players")
local DataStore = DataStoreService:GetDataStore("Frogs")

local SaveDataVersion = 2
local SaveDataVersionPatch
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
	local Builder = SessionLocker.MigratorBuilderCreate()
	
	local V2_Patch = 1
	Builder:AddMigratorFrom(1, function(SaveData)
		
		-- In save data version 2 we added the Diamonds field!
		SaveData.Diamonds = 0
		
		return V2_Patch
	end)
	Builder:AddPatcherFor(2, function(SaveData, Patch)
		
		-- In the first version of the migrator we gave people 1000 diamonds on 
		-- accident. Somebody pushed the testing code to prod.. Let's revert that 
		-- here :)
		if Patch == 0 then
			SaveData.Diamonds = math.max(SaveData.Diamonds-1000, 0)
		end
		
		return V2_Patch
	end)
	
	Builder:CheckVersion(SaveDataVersion)
	SaveDataVersionPatch = V2_Patch
	
	Migrators, Patchers = Builder:Build()
end

local Store = SessionLocker.EasyStoreCreate(
	DataStore, CreateMySaveData,
	SaveDataVersion, SaveDataVersionPatch, Migrators, Patchers)
local Profile_ByPlayer = {}

local function PlayerAdded(Player)
	local Profile = Store:StartSession(tostring(Player.UserId))
	Profile_ByPlayer[Player] = Profile
	print("Started session")
	
	if not Profile:YieldUntilLoaded() then
		warn("Failed to load session")
		
	else
		local SD: MySaveData = Profile:GetSaveData() :: any
		print(("Session loaded with gold %d"):format(SD.Gold))
		
		print("Beginning gold change & save process..")
		local DidSave = false
		
		while Profile.IsActive do
			
			print("Starting the next change attempt")
			SD.Gold += 10
			
			print(("Forcing a save of gold %d"):format(SD.Gold))
			Profile:MarkForceSave()

			DidSave = Profile:YieldUntilChangesSaved()
			if DidSave then
				break
			end
		end
		
		if DidSave then
			print("Gold saved, ending session")
		else
			print("Gold failed to save, ending session")
		end
		
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