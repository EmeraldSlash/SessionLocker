# SessionLocker

This is a reusable library for using DataStore session locking in Roblox. The system design been used in production code, but this particular library is currently untested as I have only just just extracted it out into a reusable library for use in an upcoming project.

At the moment, this library provides:
- DataStore session locking, including session reuse capabilities
- Save data migration & patching facilities
- Safe Developer Product processing, product credit, and product purchase history

Future plans:
- Make it clearer how to use `LockerState.ChangeId_*` fields to know when a particular change has been saved to the DataStore, and provide some more guarantees about it because naive polling of the `LockerState` will not work (should probably create a callback function).
- Further decouple the Developer Product stuff from the core library, and make its logic more generic so that similar operations can be performed by users of the library.
- Allow associating a `LockerState` (specifically the `DataStore` keys it writes) with more than one UserId, and fully remove all remaining limitations that force `LockerState`s to have one-to-one relationships to players.
- Increase the granularity of reusability so that if someone doesn't like one part of one particular state machine they can just rewrite it themselves and reuse the other state machines that they don't care about.
- Add support for remote changes (operations that can be remotely applied to locked `DataStore` keys by other game servers)

My approach to designing libraries is different from what most other people seem to do, so if that kind of thing interests you, go read the code. I have also provided some example files which are pretty helpful for understanding the library.

Some important things to note about the design of this library:
- The use of singletons or globals is avoided so that all important inputs can be configured by usage code and so that there are no stupid limitations (e.g. an extremely common limitation is that a library globally refers to `DataStoreService` and only supports a single `DataStore` being used, so the DataStore API can't be mocked, and I can't use more than `DataStore` with a particular library).
- I don't like thread/coroutine stuff (or derived constructs, like Promises) because it's all just a complicated nightmare of code execution, especially for APIs which are very heavy on blocking such as `DataStore`s. So instead I've designed the library to work using explicit state machines that get re-evaluated every frame for every player. This is fine: there are no performance problems, despite what people may think. Blocking Roblox API calls are isolated so that they can behave as nice pure functions with no annoying code execution side effects.

For reading the code, I recommend a tab width of 3 since that's what I wrote it with (and my Luau formatting style depends on tab width). Unfortunately GitHub does not provide this in their dropdown, but you can get it for a particular file by appending `&ts=3` to the end of the file's URL on GitHub.
