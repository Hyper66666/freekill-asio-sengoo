# Migration Map

| C++ Source | Sengoo Target | Notes |
|---|---|---|
| `src/main.cpp` | `src/runtime_native_entry.sg` | native runtime process entry |
| `src/server/server.cpp` | `src/network_sg/server_socket.sg` | server runtime/socket behavior |
| `src/server/gamelogic/rpc-dispatchers.cpp` | `src/server_sg/rpc_dispatchers.sg` | rpc dispatch compatibility |
| `src/core/packman.cpp` | `src/codec_sg/packman.sg` | package manager behavior |
| `src/server/rpc-lua/rpc-lua.cpp` | `src/ffi_bridge_sg/rpc_bridge.sg` | lua bridge call/wait/alive path |
| `src/server/task/task_manager.cpp` | `src/server_sg/task_manager.sg` | task manager state transitions |
| `src/server/user/user_manager.cpp` | `src/server_sg/user_manager.sg` | user manager state transitions |
| `src/server/room/room_manager.cpp` | `src/server_sg/room_manager.sg` | room manager state transitions |
