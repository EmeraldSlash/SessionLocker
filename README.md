# SessionLocker

This is a library for doing DataStore session locking in Roblox.

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
- Make the session locking core cleanly separated from all the extra stuff.
  - Some progress has been made on this, but two things remain: version migration, and handling of what fields are in the save data table. We can make an API to do version migration in the transform function callback, and do version migration outside of it as well. Handling of save data fields is more difficult because it is a tradeoff between convenience and robustness. The more dynamic we are, the less robust it is and the more room for error there is. The less dynamic we are, we either up redundantly storing unnecessary fields in the table which some users might not like, or we make them optional fields which has bad UX for the programmer. I think we will have to go with the dynamic approach, though, that's really the direction this library is heading.
- Need to provide examples of compression/serialization can be used with the new BeforeSaving() callback.
- Make a big upgrade of the library that merges the full and easy APIs. Most of the distinctions are unnecessary, or can achieved using a single type.
	- Remove LockerSpecs since they are kinda mid, it's probably better to specify full configuration for each player uniquely, with a composable way to reuse configuration tables if desired.
- Find ways to make typechecking a little more convenient. It's pretty good right now, but there are still two big annoyances which I'd like to resolve:
  - Passing userdata into `LockerSpec` callbacks (e.g. you have a table associated with the `LockerState` that you want to access from within a callback). My current preference is to store userdata inside `LockerState`, but this means I need to fight with the typechecker.
  - Getting `LockerState.SaveData` casted into the actual SaveData type defined by the user with minimal friction (and accessing the save data in the first place might be annoyance for some people if they'd like to store it in more convenient place)
- Allow other servers to request to take a session lock from another server, or to forcibly take session lock if they really want to.
- Some better error checking & messages so that the library has good human error UX
- Figure out if we need to do anything to deal with DataStore request limits?

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
- Complicated pipelines are explicitly implemented as state machines so that they can be easily comprehended by humans and turned into isolated reusable units of code. At the moment the library's state machines are reevaluated every frame, which is fine at the moment. If necessary the state machines can be reevaluated less frequently in the future, but I haven't added this capability yet. Blocking Roblox API calls are isolated so that they can behave as nice pure functions with no annoying code execution side effects.
  - This explicit state machine design is a reaction to the common programming style in Roblox that makes heavy use of fibers ("coroutines" / "threads") and derived constructs (like promises). That programming style complicates code execution and makes it hard to guarantee robustness, especially when there are many different sources of input into the implicit state machine. In the case of DataStore state machines, they have inputs coming from game code modifying save data or requesting data to be saved, players joining and leaving the game, the success or failure of various DataStore operations (also related to DataStore request limits), and time.

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

	while Profile.IsActive do
		SaveData.Diamonds += 1
		Profile:MarkForceSave()

		local DidSave = Profile:YieldUntilChangesSaved()
		if DidSave then
			break
		end
	end

	Profile:EndSession()
end
```
