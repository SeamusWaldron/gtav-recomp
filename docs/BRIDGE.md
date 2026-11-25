# Data bridge: stream game data from the Mac to the Vision Pro (design, 2026-11-25)

The headset app needs the checked game folder (`data/game`, `data/update`, `data/user`, about
15 GB). Copying it all with `tools/visionos/push_data.sh` is slow and breaks when the network
drops. The bridge serves the folder from the Mac and the app fetches what the game reads, when it
reads it, and keeps it. Game data and anything derived from it stay on the Mac and the headset;
none of it goes in the repo.

## What is on disk

| Root | Files | Size | Notes |
|---|---|---|---|
| game | 12 | 7.6 GB | default.xex (memory-mapped at boot), xexp, 7 big RPFs, a few small files |
| update | 1 | 54 MB | update.rpf |
| user | 11 | 7.6 GB | four HDD install partitions (`part0..3.rpf`, 1.7 to 2 GB each), profile, timestamps |

Few files, most of them large and read at random offsets. That makes a block cache the right
shape, not a whole-file cache.

## Pieces

- **Server** (`tools/bridge`, Go, standard library only). It serves `<game folder>/data/{game,update,user}`
  read-only over HTTP/1.1 on port 7360:
  - `GET /v1/manifest`: one line per entry, tab-separated: `F|D  root  size  mtime_ns  path`.
  - `GET /v1/file/<root>/<path>` with a single `Range: bytes=a-b`, which returns 206 (`http.ServeContent`).
  Hidden files are skipped. Paths are cleaned and must stay inside their root.
- **Client** (C++, `rexglue-sdk/src/core/filesystem_bridge.cpp`, POSIX sockets, no new deps). It
  starts when `--bridge_url=http://<mac>.local:7360` is set, before the VFS is mounted.

## How the client plugs in (below the VFS, not beside it)

A new VFS device would only cover `game:`. The content manager mounts the user partitions with
its own `HostPathDevice`s, and it and the profile code also call `std::filesystem` and `fopen`
directly. So the bridge sits one layer lower:

1. **Sync at start-up.** The client fetches the manifest and creates every directory, plus every
   missing file as a **sparse placeholder at its real size** (`ftruncate`; APFS stores no blocks).
   From then on `exists`, `stat`, directory listing and `HostPathDevice` behave exactly as they do with a
   full copy. Files of 256 KiB or less are fetched whole during sync, so plain `fopen` readers
   (profile, headers) never see a placeholder.
2. **Reads.** `FileHandle::OpenExisting` (the call behind every `HostPathFile`) asks the bridge
   first. For a file that is not yet complete it returns a streaming handle. That handle checks a
   per-file block bitmap (1 MiB blocks). On a miss it fetches the missing run with one Range
   request, plus 4 MiB of read-ahead, writes it into the placeholder, sets the bits, then
   `pread`s. Concurrent readers of the same block wait for one fetch.
3. **Maps.** `MappedMemory::Open` (the XEX load) first makes the whole file local.
4. **Writes.** Opening a streamed file for writing (`OpenExisting` with write access, `OpenFile`
   with `w`/`a`/`+`) first completes the file (except for `w`, which truncates it). It then
   detaches the file: the local copy owns it from then on and the server is never asked for it again.

## Cache layout

The cache is the normal layout. `Documents/data/{game,update,user}` holds the real files, so
`push_data.sh` copies and streamed copies are the same thing, and a fully streamed file is an
ordinary file. State lives in `Documents/data/.bridge/`, outside every mounted root:

- `manifest.txt`: the last manifest, used when the Mac can't be reached.
- `maps/<root>/<path>.map`: a header (magic, size, mtime, block size) and the bitmap, updated
  with a one-byte `pwrite` after each block's data is written.
- `maps/<root>/<path>.gone`: a tombstone for a file the game deleted, so sync does not bring it
  back.

Rules at sync: no local file and no map means create a placeholder. A local file with no map is
left alone; local wins (a `push_data.sh` copy, a save). A map whose size or mtime differs from the
server's means the Mac's file changed: reset the placeholder.

It goes in Documents, not Library/Caches, because the OS may purge Caches and a purged
placeholder would break the game mid-run. `UIFileSharingEnabled` already exposes Documents.

## Cache size

Without a cap, the cache grows to at most the size of the game data (16.4 GB) and nothing is
dropped. `--bridge_cache_max_gb=N` caps it. Once a second, if the cached blocks of streamed files
add up to more than N GB, the least recently read blocks are dropped. Each is cleared in the
bitmap first, then its disk space is freed with a hole (`F_PUNCHHOLE` on Apple, `fallocate` on
Linux), until the cache is back under 95% of the cap. A dropped block is fetched again the next
time it is read.

- Files made whole for a memory map or stdio (default.xex, default.xexp, every file of 256 KiB
  or less) are pinned and never dropped: a mapping would read the holes. They count toward the cap.
- Readers hold a per-file shared lock from the fetch to the `pread`, so a block can't be
  dropped mid-read. With a cap on, unpinned files stay on the streaming handle even when complete.
- Prefetch stops at 90% of the cap.
- Recency is kept in memory only. After a restart every block counts as old, so the first trim
  falls on blocks this run has not read yet.

## Network

- The client resolves the name with `getaddrinfo`. Apple's resolver handles mDNS, so
  `<LocalHostName>.local` works on any network the two devices share and survives IP changes.
  `make_app.sh` writes the Mac's name into `args.txt` when `GTAV_BRIDGE=1`.
- The headset needs `NSLocalNetworkUsageDescription` in Info.plist. The first connection
  triggers the permission prompt and fails, so the client retries for 60 s at start-up.
- Devices see each other only on a network that does not isolate clients (an iPhone hotspot
  works; plane and train Wi-Fi do not).
- If the Mac is unreachable, the client runs from the cached manifest. Reads of blocks that
  aren't cached fail with a logged error.
- Optional `--bridge_prefetch=true` fills incomplete files in the background (8 MiB requests). It
  pauses while the game is waiting on a miss. It is off by default: demand-only first, then measure.

## Known limits

- A streamed file the game renames is not tracked. Only small files get renamed (saves), and
  those are complete after sync.
- There is no per-block hash. TCP carries the data and the server's size and mtime pin the
  version. A whole-file check against the Mac can come later.
- Anyone on the same network can read the served folder while the server runs. Run it only on
  your own network or hotspot.

## Use

```sh
cd tools/bridge && go run .           # on the Mac: serves the GTAV.app game folder on :7360
# headset app: GTAV_BRIDGE=1 GTAV_GAME_DYLIB=... tools/visionos/make_app.sh --install
# Mac test against an empty folder: GTAV_HOME=<folder with gtav_game.dylib, data/spirv,
#   vulkan/share> ./dev_play_mac.sh --bridge_url=http://127.0.0.1:7360
```

macOS may ask whether the `bridge` binary can accept incoming connections. Say yes, or the
headset can't reach it.

## Results

- 2026-11-25, Mac only (M4, server reading the USB game drive, localhost). Starting from an
  empty data folder, the game booted with no dirty-disc error and no fetch errors. It reached the
  native renderer and was presenting frames by 100 s. At that point it had fetched 1.6 GB of
  16.4 GB: the xex and xexp whole, update.rpf, common.rpf, then install partitions and RPFs in
  blocks. Misses waited 100 to 170 ms on average (5 MiB requests, bound by the USB drive), at 30
  to 42 MB/s while loading.

- 2026-11-25, Mac, `--bridge_cache_max_gb=1`, starting from the 1.6 GB cache above. The cache was
  trimmed to about 1 GB at start-up and held between 0.97 and 1.02 GB while loading (934 MB on
  disk). The game kept rendering, with no errors.

## Test plan

1. (Passed 2026-11-25, see Results.) Mac only: run the server, then `gtav_fast` with an empty local data folder and
   `--bridge_url=http://127.0.0.1:7360`. It should boot to the title as it does from a full copy,
   and the cache should hold only what was read.
2. Headset on the hotspot: install with `GTAV_BRIDGE=1`, launch, and read `Documents/logs/gtav.log`
   (the bridge logs throughput and cache size every 10 s). Done means it gets past the dirty-disc
   error and renders a frame.
