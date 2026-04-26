# `rustop` — macOS Process Monitor in Rust
### Weekend Project — Implementation Notes

---

## Project Goal

Build a terminal CLI tool that displays a live-refreshing table of running processes
(PID, name, CPU%, memory, threads), reading directly from the macOS kernel via `sysctl`
and `libproc`. The goal is to practice `Mutex`, `Cell`, `Arc`, and multi-threading in a
real systems context.

---

## Cargo.toml

```toml
[dependencies]
libc = "0.2"          # raw access to sysctl, proc_pidinfo, kinfo_proc etc.
crossterm = "0.27"    # terminal control: clear screen, cursor, raw mode, key events
clap = { version = "4", features = ["derive"] }  # CLI args (--sort, --filter, --interval)
```

> Avoid `procfs` or any macOS-specific process crate — the whole point is doing it raw.

---

## Module Layout

```
src/
├── main.rs           # entry point, thread spawning, CLI args
├── fetch.rs          # macOS sysctl + proc_pidinfo calls (unsafe)
├── process.rs        # ProcessInfo struct, Cell usage
├── table.rs          # shared ProcessTable, Mutex usage
├── display.rs        # terminal rendering with crossterm
└── input.rs          # keyboard listener thread
```

---

## Module Notes

---

### `process.rs` — The Core Struct

This is where `Cell` lives. `prev_cpu_ticks` needs to be mutated between two samples
to compute a CPU delta, but it belongs to a single thread (the fetcher), so no lock is
needed — `Cell<u64>` is perfect.

```rust
use std::cell::Cell;

pub struct ProcessInfo {
    pub pid:            u32,
    pub name:           String,
    pub cpu_percent:    f64,
    pub mem_kb:         u64,
    pub threads:        u32,
    pub prev_cpu_ticks: Cell<u64>,   // <-- Cell, not Mutex. No cross-thread sharing here.
    pub prev_sample_ts: Cell<u64>,   // timestamp of last sample in ms
}
```

**Hints:**
- `Cell<T>` only works for `Copy` types — `u64` qualifies
- `Cell` is `!Sync`, so `ProcessInfo` itself won't be `Sync` — that's fine, the struct
  lives *inside* the `Mutex`, it never crosses threads on its own
- Compute CPU% as `(delta_ticks / delta_time) * 100.0` between two calls to `fetch.rs`

---

### `table.rs` — Shared State Between Threads

This is where `Mutex` + `Arc` live. The fetcher thread writes, the display thread reads.
Both need access, so you wrap the whole table in `Arc<Mutex<...>>`.

```rust
use std::sync::{Arc, Mutex};
use crate::process::ProcessInfo;

pub struct ProcessTable {
    pub entries:     Vec<ProcessInfo>,
    pub sort_by:     SortKey,
    pub filter:      Option<String>,
    pub total_procs: usize,
}

pub type SharedTable = Arc<Mutex<ProcessTable>>;
```

**Hints:**
- Clone the `Arc` before passing to each thread — don't move it
- Keep the lock held for the *shortest time possible*: fetch all data first,
  then lock, write, unlock. Never do I/O or sleeping while holding the lock
- `SortKey` can be a simple enum: `Cpu`, `Memory`, `Pid`, `Name`
- Consider a second `Arc<Mutex<bool>>` as a "should_quit" flag shared across all threads

---

### `fetch.rs` — Talking to the macOS Kernel

All `unsafe` lives here. Two main syscalls:

**1. Get the list of all PIDs** via `sysctl(KERN_PROC_ALL)`:
- Call it twice: once with a null buffer to get the required size, once to fill a
  `Vec<kinfo_proc>`
- `kinfo_proc.kp_proc.p_pid` → PID
- `kinfo_proc.kp_proc.p_comm` → process name (fixed-length C string, use `CStr`)

**2. Get per-process stats** via `proc_pidinfo(pid, PROC_PIDTASKINFO, ...)`:
- Fills a `proc_taskinfo` struct
- `pti_resident_size` → RAM in bytes → divide by 1024 for KB
- `pti_total_user + pti_total_system` → total CPU ticks (nanoseconds on macOS)
- `pti_threadnum` → thread count
- Returns ≤ 0 on permission denied — handle gracefully with `Option`

**Hints:**
- Wrap everything in a `pub fn fetch_all() -> Vec<ProcessInfo>` that `table.rs` calls
- You won't be able to read every process without `sudo` — that's expected, just skip them
- Use `std::mem::zeroed()` to initialise the structs before passing pointers to C
- Use `std::time::SystemTime` to timestamp each fetch for the CPU delta calculation

---

### `display.rs` — Terminal Rendering

Use `crossterm` to manage the terminal. No need for a full TUI library like `ratatui`
for this project — raw crossterm keeps it lean.

Key crossterm primitives to use:
- `terminal::enable_raw_mode()` — call once at startup, disable on exit
- `execute!(stdout, Clear(ClearType::All), cursor::MoveTo(0, 0))` — to redraw
- `Print(...)` — write formatted rows

**Hints:**
- Build a `fn render(table: &ProcessTable)` that takes a lock snapshot and draws everything
- Format CPU% with `{:.1}` and right-pad columns with `{:<15}` style formatting
- Add a header row with column names and a separator line
- Show a status bar at the bottom: total process count, refresh interval, sort mode
- Handle terminal resize gracefully — `crossterm::event::EventKind::Resize` fires on resize

---

### `input.rs` — Keyboard Listener Thread

Runs on its own thread. Polls for key events using `crossterm::event::poll` and writes
to a shared flag when the user presses `q`.

**Hints:**
- Use `Arc<Mutex<bool>>` for the quit flag, or better yet `Arc<AtomicBool>` from
  `std::sync::atomic` — atomics are perfect for a single boolean signal between threads,
  no `Mutex` overhead needed
- Poll with a short timeout (e.g. 100ms) so the thread stays responsive
- You can extend this later to handle arrow keys for sorting or `f` for filtering

---

### `main.rs` — Thread Orchestration

Spawn three threads:

```
main
├── thread: fetcher    — loops every N ms, calls fetch::fetch_all(), locks table, writes
├── thread: display    — loops every N ms, locks table, reads, calls display::render()
└── thread: input      — blocks on key events, sets quit flag
```

**Hints:**
- Use `std::thread::spawn` + `Arc::clone` to share the table and quit flag
- Pass the refresh interval via CLI arg (default 1000ms), store it as a `u64`
- Use `std::thread::sleep(Duration::from_millis(...))` for the loop timing
- Call `thread.join().unwrap()` on all handles before exiting so the terminal is
  properly restored
- Wrap your `main` body in a function that returns `Result` so you can use `?` cleanly

---

## Threading Diagram

```
┌─────────────────┐    Arc<Mutex<ProcessTable>>    ┌─────────────────┐
│  fetcher thread │ ──────────── write ──────────► │                 │
└─────────────────┘                                │  ProcessTable   │
                                                   │   (Mutex)       │
┌─────────────────┐                                │                 │
│  display thread │ ──────────── read  ──────────► │                 │
└─────────────────┘                                └─────────────────┘

┌─────────────────┐    Arc<AtomicBool>
│  input thread   │ ──── sets quit flag ───────────► all threads check & exit
└─────────────────┘
```

---

## Suggested Weekend Schedule

**Saturday morning** — `fetch.rs` + `process.rs`
Get `sysctl` working, print raw PID list to stdout. Add `proc_pidinfo`. Get a
`Vec<ProcessInfo>` printing correctly in a loop. This is the hardest part.

**Saturday afternoon** — `table.rs` + `main.rs` threading
Wrap in `Mutex`, spawn the fetcher thread, verify no data races. Add the quit flag.

**Sunday morning** — `display.rs`
Make the table actually look good in the terminal. Add column alignment, colors,
the status bar. Wire in `crossterm` raw mode properly.

**Sunday afternoon** — `input.rs` + CLI args + polish
Add keyboard handling and `clap` args. Sort by CPU on startup. Add `--filter`.
Handle `sudo` vs non-sudo gracefully with a message.

---

## Useful References

- [`libc` crate docs](https://docs.rs/libc) — search `kinfo_proc`, `proc_taskinfo`
- [`crossterm` docs](https://docs.rs/crossterm) — terminal, event, style modules
- `man 3 proc_pidinfo` in your terminal — the real macOS reference
- `man 8 sysctl` — explains the MIB (management information base) system
- The source of `htop` or `btop` on GitHub — good to read, don't copy

---

## Stretch Goals (if you finish early)

- **Sparkline bars** — render a mini ASCII bar for CPU% next to each row
- **Process tree** — use `kinfo_proc.kp_eproc.e_ppid` to build a parent-child tree view
- **Config file** — save sort preference and refresh rate to `~/.config/rustop/config.toml`
- **Cross-platform** — abstract `fetch.rs` behind a `trait ProcessSource` and add a
  Linux implementation that reads `/proc`
