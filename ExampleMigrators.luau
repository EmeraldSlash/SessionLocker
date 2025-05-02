--!strict

local Module = {}

local SessionLocker = require(game.ServerScriptService.SessionLocker)

local Migrators = {} :: {[number]: SessionLocker.SaveDataMigrator}
Module.Migrators = Migrators

local Patchers = {} :: {[number]: SessionLocker.SaveDataPatcher}
Module.Patchers = Patchers

type SD_V1 = {
	ExampleMoney: number;
	ExampleRemovedFeature: string;
}

type SD_V2 = {
	ExampleMoney: number;
	ExamplePlaytime: number;
}

Module.Migrators[1] = function(SD_V1: SD_V1)
	
	SD_V1.ExampleRemovedFeature = nil :: any
	
	local SD_V2: SD_V2 = SD_V1 :: any
	SD_V2.ExamplePlaytime = 0
	
	return 0
end

return Module