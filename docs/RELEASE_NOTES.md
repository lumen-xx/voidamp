Native macOS menu bar audio mixer with signed Sparkle updates. Requires macOS 14.2 or newer and an Apple silicon Mac.

**New in this version**
- **Undo in the Suite:** ⌘Z undoes adding, moving and removing nodes and connecting or disconnecting wires; removed nodes come back with their wires. ⇧⌘Z redoes.
- **Quitting asks first** while an app such as Discord records from a virtual mic Voidamp is feeding, because that app would hear silence. Logging out, restarting and updates still quit straight away.
- **Volume and brightness keys** are now read on their own thread, so they respond at once even while the Suite is busy, and macOS no longer switches them off after a slow moment.
- A virtual mic on the board now says how many sources are wired into it.
- Settings end with links to GitHub and opyuii.com.
