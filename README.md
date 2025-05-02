# SessionLocker

This is a reusable library for using DataStore session locking in Roblox. The system design been used in production code, but this particular module is currently untested as I have only just just extracted it out into a reusable library.

At the moment, this library provides:
- DataStore session locking
- Save data migration & patching facilities
- Safe Developer Product processing, product credit, and product purchase history

Future plans:
- Make it clearer how to use LockerState.ChangeId_* fields to know when a particular change has been saved to DataStore, and provide some more guarantees about it because naive polling of the LockerState will not work (should probably create a callback function).
- Further decouple the Developer Product stuff from the core library, and make its logic more generic so that similar operations can be performed by users of the library.

My approach to designing libraries is different from what most other people seem to do, so if that kind of thing interests you, go read the code. I have also provided some example files which are pretty helpful for understanding the library.
