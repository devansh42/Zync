# Zync is a Coroutine runtime (inspired by Go Runtime)

This implements
* Coroutine multiplexing over Threads
* Userspace WaitGroups
* Userspace Sleep
* Spin Lock
* Seperate Stack for every Coroutine (32KB)

WIP
* Mutex
* RWMutex
* Channels
* Select Statement
* Automatic Stack expansion for Coroutine
* Gracefull shutdown of runtime

Disclaimer:
**Current implementation is available for Arm64 processors as it's uses Arm64's assembly instructions to switch Stacks during context switches**
