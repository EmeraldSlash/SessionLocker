# SessionLocker

This is a library for doing DataStore session locking in Roblox. The system design been used in production code, but this particular codebase has not been battle-tested yet as I have only just just extracted it out into a reusable library for use in an upcoming project.

For reading the code, I recommend a tab width of 3 since that's what I wrote it with (and my Luau formatting style depends on tab width). Unfortunately GitHub does not provide this tab width as a selectable option, but you can get it for a particular file by appending `?ts=3` to the end of the file's URL.

At the moment, this library provides:
- DataStore session locking, including session reuse capabilities
- Facilities for save data version migration & patching, and merging offline save data into online save data
- Reliable tracking of when save data changes have been saved to DataStore
- Queuing modifications to save data without having a session lock, then applying those modifications when data loads ("Remote Changes")
- Safe Developer Product processing, credit, and purchase history

The library intentionally does not provide (see the Design section below for discussion):
- Client/server replication of save data
- Change signals/callbacks/detection for individual fields of save data

Future plans:
- Make the session locking core cleanly separated from all the extra stuff. Decouple Developer Product stuff, and perhaps even remote changes and data version migration, from the core session locking system.
- Rethink how the library treats save data - should it be owned by the usage code rather than the library? Need to support compression / serialization use cases.
- Figure out how to deal with DataStore request limits.
- Add some affordances for fields like `LockerState.InUse` so that different pieces of code may prevent the session from being released without knowing about each other. I guess I should just make it an array of values rather than a bool?
- Find ways to make typechecking a little more convenient. It's pretty good right now, but there are still two big annoyances which I'd like to resolve:
  - Passing userdata into `LockerSpec` callbacks (e.g. you have a table associated with the `LockerState` that you want to access from within a callback). My current preference is to store userdata inside `LockerState`, but this means I need to fight with the typechecker.
  - Getting `LockerState.SaveData` casted into the actual SaveData type defined by the user with minimal friction (and accessing the save data in the first place might be annoyance for some people if they'd like to store it in more convenient place)
- Some better error checking & messages so that the library has good human error UX


## Design

There are some common limitations in Roblox DataStore libraries that I am trying to avoid in SessionLocker:
- A library globally refers to `DataStoreService` so the DataStore API can't be mocked
- A library only supports a single `DataStore` being used so if you need more then you have to duplicate the library or do it yourself.
- A library forcibly binds itself to top-level signals or callbacks, such as `game:BindToClose()` and `Players.PlayerAdded/PlayerRemoving`, meaning usage code has no control over where or when the library does things.
- A library does not clearly define or limit how code is executed, so it's often unclear when it's safe or not safe to do things, and one has to write code defensively. It is also often written in a way that's quite convoluted, so it's kind of like a magical black box that programmers using it have difficulty understanding.
- A library couples DataStore logic with client/server replication and specific data modification & change detection approaches, which forces particular code architectures and increases abstraction.

 To avoid these pitfalls, note these following aspects of the library's design:
- The library should be thought of as a backend that is relatively neutral about architectural details.
- The use of singletons or globals is avoided so that all inputs can be configured by usage code.
- All code execution can be controlled by the usage code (except for isolated operations without side effects). But the library can still have _optional_ convenience APIs which execute code on their own, if the user doesn't care.
- Complicated pipelines are explicitly implemented as state machines so that they can be easily comprehended by humans and turned into isolated reusable units of code. At the moment the library's state machines are reevaluated every frame, which is fine at the moment: there are no performance problems. If necessary the state machines can be reevaluated less frequently in the future, but I haven't added this capability yet. Blocking Roblox API calls are isolated so that they can behave as nice pure functions with no annoying code execution side effects.
  - This explicit state machine design is a reaction to the common programming style in Roblox that makes heavy use of fibers ("coroutines" / "threads") and derived constructs (like promises). That programming style complicates code execution and makes it hard to guarantee robustness, especially when there are many different sources of input into the implicit state machine. In the case of DataStore state machines, they have inputs coming from game code modifying save data or requesting data to be saved, players joining and leaving the game, the success or failure of various DataStore operations (also related to DataStore request limits), and the steady, unstoppable advancement of time.

## Usage Examples

Using the easy API:
```luau
local Store = SessionLocker.EasyStoreCreate(DataStore, function()
	return {Gold = 0; Diamonds = 0;}
end)

local Profile = Store:StartSession(tostring(UserId))
if Profile:YieldUntilLoaded() then

	local SaveData = Profile:GetSaveData()

	SaveData.Gold += 10
	Profile:MarkShouldSave()

	while true do
		SaveData.Diamonds += 1
		Profile:MarkForceSave()

		local ChangeStatus = Profile:YieldUntilChangesSaved()
		if ChangeStatus ~= "replaced" then
			break
		end
	end

	Profile:EndSession()
end
```
