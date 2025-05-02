# SessionLocker

This is a reusable library for using DataStore session locking in Roblox. The system design been used in production code, but this particular module is currently untested as I have only just just extracted it out into a reusable library.

At the moment, this library provides:
- DataStore session locking
- Save data migration & patching facilities
- Safe Developer Product processing, product credit, and product purchase history

Future plans:
- Make it clearer how to use LockerState.ChangeId_* fields to know when a particular change has been saved to DataStore, and provide some more guarantees about it because naive polling of the LockerState will not work (should probably create a callback function).
- Further decouple the Developer Product stuff from the core library, and make its logic more generic so that similar operations can be performed by users of the library.
- Allow associating a LockerState (and its DataStore entries) with more than one UserId, and full remove all remaining limitations that force LockerStates to have one-to-one relationships to players.

My approach to designing libraries is different from what most other people seem to do, so if that kind of thing interests you, go read the code. I have also provided some example files which are pretty helpful for understanding the library.

Some important things to note about the design of this library:
- The use of singletons or globals is avoided so that all important inputs can be configured by usage code and so that there are no stupid limitations (e.g. the module globally refers to DataStoreService and only supports a single DataStore being session locked, so the DataStore API can't be mocked, and I can't have more than DataStore being session locked using just this library).
- Rather than having lots of complicated threading/coroutine stuff going on (or derived constructs, like Promises), the module is designed to work as an explicit state machine that gets re-evaluated every frame for every player. This is fine: there are no performance problems. Blocking Roblox API calls are isolated so that they can behave as nice pure functions with no annoying code execution side effects.
