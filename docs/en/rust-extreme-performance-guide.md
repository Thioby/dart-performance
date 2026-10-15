> 🇬🇧 English version · [🇵🇱 Wersja polska](../rust-extreme-performance-guide.md)

# How to write extremely fast Rust code — a workshop based on the "Twelve Dollar Server Challenge"

> Source: https://github.com/arjaythedev/twelve-dollar-server-challenge
> Submissions are not on `main` but in open PRs (`refs/pull/N/head`). Directories analyzed:
>
> | Submission | PR | Files | Role in this guide |
> |---|---|---|---|
> | `submissions/rust-epoll-scooter1337` | #19 | `src/uring.rs` (915 LOC), `src/net.rs` (437), `src/db.rs` (536), `src/main.rs` (491), `build.rs`, `Cargo.toml`, `IO_URING.md`, `BENCHMARKS.md` | **Winner** — Rust + raw `io_uring` (the "epoll" directory name is historical; the epoll path remained in `net.rs` as the `--epoll` comparison variant) |
> | `submissions/rust-axum-tbsvttr` | #17 | `src/main.rs` (441 LOC), `Cargo.toml` | Rust #1 — Axum, 1 Tokio thread (`current_thread`), DB actor with group commit, directly on port 80, cuts keep-alive above 40,000 connections |
> | `submissions/rust-axum-SvetlinZarev` | #22 | `src/db.rs`, `src/api/*.rs`, `src/auth.rs` | Second Axum — behind Nginx, separate writer thread + read-only connections per thread, jemalloc |
> | `submissions/cpp-eastl-io_uring-pgo-hendy643` | #32 | `src/server.cpp`, `src/block_pool.hpp`, `src/conn.hpp`, `src/jwt.cpp`, `src/db.cpp` | C++ 64k — the same model as the winning Rust, with interesting differences |
> | `submissions/zig-usockets-tbsvttr` | #25 | `src/main.zig`, `src/app.zig` | Zig 61k — uSockets + picohttpparser, group commit per loop iteration |
> | `submissions/dart-rawsocket-C-Hatton` | #46 | `bin/server.dart` | Dart — the same set of tricks in Dart (see the Dart guide) |
>
> The numbers "64k users, p99 224 ms, 52 % CPU, < 100 MB RAM" and "43k, 1.1 GB RAM" come from the organizer's benchmark summary (your summary). In the repository the authors have their own measurements — I quote them when they help understand *why*.

---

## 0. Mental model: where 64,000 connections on 1 vCPU come from

Before we get into the code, three numbers that organize everything else:

1. **Time budget.** k6 generates about 40,000 req/s for 64k users (each user "thinks" 3–15 s between requests). One vCPU has 1,000,000 µs/s. At 52 % CPU that works out to **~13 µs per request** — including the kernel (TCP), HTTP parsing, HMAC-SHA256, SQLite and sending. Every allocation (~50–100 ns), every syscall (~0.5–1 µs), every context switch (~2–5 µs) is a noticeable fraction of that budget.
2. **Memory budget.** 64,000 connections in 100 MB is **~1.5 KB per connection** (including kernel buffers!). If your application holds a 16 KB read buffer, a Tokio task and a hyper structure per connection, then 64k × ~20 KB = 1.3 GB — and that is exactly the Axum story.
3. **fsync budget.** Every `COMMIT` in WAL with `synchronous=NORMAL` is at least a write to the WAL file and a pager/lock cycle. At ~1,000 writes/s (15 % likes + 2 % posts), one COMMIT per *batch* instead of per request is the difference between "SQLite is the bottleneck" and "SQLite is 4 % of the profile".

The winning architecture minimizes all three at once: **one event loop per ring, zero allocations per request, one COMMIT per batch of completions**.

---

## 1. I/O architecture: `io_uring` vs Tokio/Axum

### 1.1 How the winner configures `io_uring` (`src/uring.rs`)

The ring is created per worker thread, in `Worker::new`:

```rust
// src/uring.rs, Worker::new
let ring = IoUring::builder()
    .setup_cqsize(8192)          // completion queue larger than SQ (1024): batches of CQEs
    .setup_coop_taskrun()        // the kernel does not interrupt the thread with an IPI, it finishes the work on syscall entry
    .setup_single_issuer()       // only this thread submits SQEs -> the kernel skips locking
    .setup_defer_taskrun()       // "task_work" deferred until the next entry into io_uring_enter
    .build(1024)?;
ring.submitter().register_files_sparse(slots as u32)?;   // descriptor table *inside the ring*, 65535 slots
let recv_memory = Mapping::new(NBUFS * BUFSIZE)?;        // 1024 x 2048 B = 2 MB, anonymous mmap
let descriptors = Mapping::new(NBUFS * size_of::<types::BufRingEntry>())?;
let registered = unsafe {
    ring.submitter().register_buf_ring_with_flags(descriptors.ptr.as_ptr() as u64, NBUFS as u16, GROUP, 0)
}.is_ok();
```

Four decisions and what they mean:

| Flag / call | What it does | Why it matters at 64k connections |
|---|---|---|
| `SINGLE_ISSUER` + `DEFER_TASKRUN` + `COOP_TASKRUN` | The kernel assumes one thread services the ring and does not wake it asynchronously; `task_work` (e.g. delivering TCP data to a CQE) runs only on the next `io_uring_enter` | Instead of thousands of wakeups per second, the loop wakes once, collects a *batch* of completions and handles them in bulk. This is the foundation of group commit |
| `register_files_sparse(65535)` | Registers an empty table of 65,535 "fixed files" inside the ring | Accepted sockets land **in this table, not in the process FD table**. `LimitNOFILE=65535` stops being the limit on the number of connections: 8 rings × 65,535 = 524,280 slots. Moreover, every `recv`/`send` through `types::Fixed(fd)` bypasses `fget()`/`fput()` (refcount on `struct file`) in the kernel |
| `register_buf_ring` (provided buffers) | 1024 buffers of 2 KB in a single `mmap`, described in a ring the kernel reads itself | Multishot `recv` needs no buffer *per connection*. 64,000 idle keep-alive connections **hold no read buffer at all** — the kernel picks a buffer only when data arrives. This is the main reason for < 100 MB RSS |
| `setup_cqsize(8192)` | CQ larger than SQ | Multishot accept/recv generate many CQEs from one SQE; a CQ overflow (`-ENOBUFS`) would be a disaster |

Operations submitted to the ring (all in `uring.rs`):

```rust
fn accept(&mut self) {
    self.accept_generation = self.accept_generation.wrapping_add(1);
    let e = opcode::AcceptMulti::new(types::Fd(self.listener))
        .allocate_file_index(true)                // the kernel itself picks a free slot in the ring table
        .build()
        .user_data(tag(ACCEPT, 0, self.accept_generation));
    self.queue(e);
}
fn recv(&mut self, fd: usize) {
    let e = opcode::RecvMulti::new(types::Fixed(fd as u32), GROUP)   // multishot + provided buffers
        .build()
        .user_data(tag(RECV, fd, self.clients[fd].generation));
    self.queue(e);
    self.clients[fd].state |= RECEIVING;
}
fn send(&mut self, fd: usize) {
    let c = &mut self.clients[fd];
    let e = opcode::Send::new(types::Fixed(fd as u32),
                              unsafe { c.flight.ptr.add(c.sent as usize) },
                              c.flight.len - c.sent)
        .flags(libc::MSG_NOSIGNAL)
        .build()
        .user_data(tag(SEND, fd, c.generation));
    c.state |= SENDING;
    self.queue(e);
}
```

`user_data` is a 64-bit tag encoding the operation, the slot and the **generation**:

```rust
fn tag(op: u64, fd: usize, generation: u32) -> u64 {
    op | ((fd as u64) << 8) | ((generation as u64) << 32)
}
```

The generation solves the classic event-loop problem: the connection in slot 17 was closed, slot 17 got a new client, and a stale CQE for slot 17 still falls out of the ring. `on_recv`/`on_send` check `self.clients[fd].generation == generation` and ignore zombies. The same trick is in C++ (`conn_tag(op, gen, fd)` in `server.cpp`).

### 1.2 The event loop step by step (`Worker::run`)

```rust
fn run(mut self, shared: Arc<Mutex<App>>) -> ! {
    let mut last_count = 0;
    loop {
        // (1) How many completions to wait for and for how long? Under load: up to 32 CQEs or 250 µs.
        //     Idle: 1 CQE, up to 2 s. This is the batching "governor".
        let timeout = if last_count >= 4 { Timespec::new().nsec(self.tuning.wait_us * 1000) }
                      else { Timespec::new().sec(2) };
        let wait = if !self.ready.is_empty() { 0 }
                   else if last_count >= 4 { self.tuning.batch.min(self.open.saturating_mul(2).max(1)) }
                   else { 1 };
        // (2) ONE syscall: submit all queued SQEs and wait for `wait` CQEs.
        let result = self.ring.submitter().submit_with_args(wait, &SubmitArgs::new().timespec(&timeout));
        // ... handle ETIME/EINTR/EAGAIN/EBUSY as "nothing happened" ...
        // (3) Drain ALL completions into a local Vec (so as not to hold a borrow on the ring).
        self.completions.clear();
        self.completions.extend(self.ring.completion().map(|c| (c.user_data(), c.result(), c.flags())));
        last_count = self.completions.len();
        // (4) Take the mutex on App (SQLite + Auth) ONCE for the whole batch.
        let mut app = shared.lock().unwrap();
        // (5) First the connections with deferred (pipelined) input...
        for _ in 0..self.ready.len().min(128) { /* process(fd, &[], &mut app) */ }
        // (6) ...then every completion: accept -> new Client; recv -> parse + serve; send -> release buffer.
        for i in 0..self.completions.len() {
            let (tag, result, flags) = self.completions[i];
            let fd = ((tag >> 8) & 0xffffff) as usize;
            let generation = (tag >> 32) as u32;
            match tag & 255 {
                ACCEPT => self.on_accept(generation, result, flags),
                RECV => self.on_recv(fd, generation, result, flags, &mut app),
                SEND => self.on_send(fd, generation, result),
                _ => {}
            }
        }
        // (7) Give the consumed read buffers back to the kernel (one Release store on the ring tail).
        self.publish_buffers();
        // (8) GROUP COMMIT: one COMMIT for all writes in this batch.
        let committed = app.db.commit();
        // (9) Only now do the responses go to the ring (or turn into 500s if the COMMIT failed).
        self.flush(committed);
        // (10) WAL checkpoint off the critical path (only when >= 1000 frames).
        app.db.checkpoint();
        drop(app);
        // (11) Resume accept if room has freed up; every 10 s close connections stalled > 120 s.
        if !self.accepting && self.slots - self.open >= self.reserve * 2 { self.accept(); }
        // ...
    }
}
```

Note three things that are absent from a typical loop:

* **Responses are not sent in `on_recv`.** `process()` writes the response to `clients[fd].output` and registers it in `self.pending` (`Pending { fd, generation, start, count, interim }`). Sending happens in `flush()` **after COMMIT**. This is "every response waits for its commit" from rule 6 — implemented without any channel, oneshot or futures.
* **The "in-flight" buffer is separate.** `flush()` does `c.flight = std::mem::take(&mut c.output)`. Until the kernel reports a CQE for the `send`, `flight` may neither move nor be freed (the SQE holds a raw pointer). New responses in the meantime go to a fresh `output`. After `on_send` the buffer returns to the pool (`retire`: max 256 buffers ≤ 16 KB per ring).
* **Backpressure without async.** When `output.len >= OUTPUT_HIGH` (64 KB), `pause(fd)` cancels the multishot recv (`AsyncCancel`) — a client that does not read responses stops being read. `on_send` resumes reading below half the threshold.

### 1.3 Connection structure: 64 bytes, exactly one cache line

```rust
/// A compact owning buffer. Its allocation never moves while a send is in flight.
/// Keeping lengths as u32 makes a complete connection fit one 64-byte cache line.
#[repr(C)]
#[derive(Default)]
struct Buffer { ptr: *mut u8, len: u32, cap: u32 }        // 16 B (Vec<u8> would be 24 B)

#[repr(C)]
#[derive(Default)]
struct Client {
    input: Buffer,    // partial request (usually empty: cap == 0, no allocation)
    output: Buffer,   // responses waiting for commit
    flight: Buffer,   // response currently being sent
    sent: u32,
    generation: u32,
    touched: u32,     // seconds since start, for the 120 s sweep
    state: u32,       // bitflags LIVE|RECEIVING|SENDING|CLOSING|SHUT|PAUSED|DIRTY|CONTINUED|READY + index into pending
}
const _: () = assert!(std::mem::size_of::<Client>() == 64);
```

`Vec<Client>` grows in steps of 1024 (`resize_with` in `on_accept`). 64,000 connections = **4 MB** of application state. Compare: C++ has the identical idea (`struct Conn` 64 B in an `mmap`-ed table indexed by slot, `conn.hpp`), Zig keeps `Connection` in the uSockets socket extension (`us_socket_ext`).

### 1.4 Why Axum used 1.1 GB at 43k while `io_uring` used < 100 MB at 64k

The code in `rust-axum-tbsvttr/src/main.rs` is short and idiomatic — and that is exactly the problem. Let's trace one keep-alive connection and one request:

```rust
// rust-axum-tbsvttr/src/main.rs
async fn handle(State(queue): State<mpsc::Sender<Job>>, request: Request) -> Response {
    let (parts, body) = request.into_parts();
    let data = match to_bytes(body, 16384).await { ... };     // Bytes (allocation when body > 0)
    let (done, result) = oneshot::channel();                   // Arc<Inner> on the heap
    let job = Job {
        method: parts.method.to_string(),                      // String #1
        path: parts.uri.path().to_owned(),                     // String #2
        auth: parts.headers.get(header::AUTHORIZATION)...to_owned(), // String #3 (~300 B JWT)
        body: data.to_vec(),                                   // Vec #4 (copy of body)
        done,
    };
    if queue.send(job).await.is_err() { ... }                  // Job goes through mpsc
    http_response(result.await.unwrap_or_else(|_| failure(500, "internal server error")))
}
```

and on the DB actor side:

```rust
fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Post> {
    Ok(Post { id: row.get(0)?, body: row.get(1)?,            // String per text column
              created_at: row.get(2)?, author: row.get(3)?, like_count: row.get(4)? })
}
// feed: 20 x Post = 60 Strings + Vec<Post>, then:
fn reply(status: u16, value: impl Serialize) -> Reply {
    (status, serde_json::to_vec(&value).expect("serializable response"))   // another Vec
}
```

**Per request** that is ~70–80 heap allocations and several copies of the same bytes (SQLite → `String` → `serde_json` → `Vec<u8>` → `Body` → hyper write buffer). At 40k req/s that is millions of allocations per second — CPU, but not 1.1 GB. The memory comes from **per connection**:

| Component per keep-alive connection in Axum/hyper/Tokio | Estimate |
|---|---|
| The `hyper::server::conn::http1::Connection` task future (HTTP/1 server state machine + Router + Service), allocated by `tokio::spawn` | 1–3 KB |
| hyper read buffer (`read_buf`; starts at 8 KB and grows with an adaptive strategy, retained for the duration of keep-alive) | 8 KB+ |
| hyper write buffer (`write_buf`, headers + body, retained) | 8 KB |
| `TcpStream` + registration in `mio`/epoll, `ScheduledIo`, `Waker`s | ~0.3 KB |
| `ConnectionInfo { Arc<ConnectionLease> }` from `into_make_service_with_connect_info` | 0.1 KB |
| System allocator fragmentation (glibc malloc keeps per-thread arenas, does not return memory) | ×1.3–1.5 |

That gives **~20–25 KB per connection**, and 43,000 × 25 KB ≈ **1.05 GB**. The author measured it himself: "Peak process RSS was 978.9 MiB" at 70,000 users on ARM64, and added a safety valve:

```rust
static KEEPALIVE_LIMIT: AtomicUsize = AtomicUsize::new(40000);
fn http_response((status, data): Reply) -> Response {
    let mut builder = Response::builder();
    if CONNECTIONS.load(Ordering::Relaxed) >= KEEPALIVE_LIMIT.load(Ordering::Relaxed) {
        builder = builder.header(header::CONNECTION, "close");   // <- "above 40k it started closing connections"
    }
    ...
}
```

This is exactly the behavior you saw in the benchmark: above ~40k the server cuts keep-alive on its own, because otherwise it would run out of RAM.

For comparison, `io_uring`:

| Component | Winning Rust |
|---|---|
| Connection state | 64 B in `Vec<Client>` |
| Read buffer | **0 B when idle** — 1024 shared 2 KB buffers per ring (2 MB/ring), the kernel assigns them only for the time it takes to deliver data |
| Write buffer | 0 B when idle; pool of max 256 × ≤16 KB per ring (≤ 4 MB/ring), returned after the send CQE |
| Descriptor | slot in the ring table (a few dozen bytes in the kernel), no `struct file` in the process FD table |
| Task / future / waker | none — the state is bitflags in `Client.state` |

Total: 64k × 64 B (4 MB) + 8 rings × (2 MB + 4 MB + CQ/SQ ~0.3 MB) ≈ **55 MB** upper bound for the application part, plus SQLite (`cache_size=500` pages, mmap 1 GiB — but that is the OS page cache, not anonymous memory). From `IO_URING.md`: "Mixed RSS is 40.09 → 41.06 MiB", and at 365,500 users "median anonymous memory 31.94 MiB" (the rest is kernel memory for sockets).

**General conclusion (not only for io_uring):** the memory of a server with a large number of keep-alive connections is the product `number_of_connections × idle_connection_state`. Every byte held *per idle connection* counts 64,000 times. A framework that holds an 8 KB buffer "because a request might come" loses to the model "assign the buffer only when there is data" — and that is exactly what provided buffers in io_uring give you (or, in the epoll world, a shared `scratch` buffer as in `net.rs`: `let mut scratch = vec![0u8; 65536];` one for the whole loop).

### 1.5 Threads vs rings: why 8 workers on 1 vCPU make sense

```rust
// src/uring.rs, run()
let slots = limits.rlim_max.min(TARGET_SLOTS as libc::rlim_t) as usize;   // 65535 on the organizer's box
let workers = TARGET_SLOTS.div_ceil(slots).min(MAX_WORKERS);              // 524280 / 65535 = 8
```

The 8 threads did not come about for parallelism (on 1 vCPU that would gain nothing). The fixed-files table in a ring cannot be larger than `RLIMIT_NOFILE`, so 8 rings × 65,535 = capacity for 524,280 connections. Each thread has its own ring, but **they all share a single `Arc<Mutex<App>>`** held for the entire time a batch is being serviced — SQLite compiled with `SQLITE_THREADSAFE=0` is never called concurrently. With a limit of 1,048,576 the author creates 1 ring with 524,280 slots and measures that it is slightly better (less coordination). C++ (hendy643) solved it differently: 5 rings serviced by *one* thread, filled in turn.

---

## 2. The Group Commit pattern (batching SQLite transactions)

### 2.1 The `io_uring` version: deferred transaction, commit per batch of CQEs (`src/db.rs`)

```rust
pub struct Db {
    feed: Stmt, feed_ids: Stmt, feed_likes: Stmt, feed_rows: Stmt, feed_scratch: Vec<u8>,
    post: Stmt, health: Stmt, insert: Stmt, created: Stmt, like: Stmt, exists: Stmt,
    begin_stmt: Stmt, commit_stmt: Stmt, rollback_stmt: Stmt,     // BEGIN/COMMIT are prepared too!
    raw: *mut Connection,
    wal_frames: Box<Cell<i32>>,
    pub transaction: bool,
    pub group: bool,
}

fn begin(&mut self) -> bool {
    if !self.group || self.transaction { return true; }        // already in a transaction -> nothing
    if !Self::transaction_step(&mut self.begin_stmt) { return false; }
    self.transaction = true;
    true
}
pub fn commit(&mut self) -> bool {
    if !self.transaction { return true; }                      // a batch without any query
    let ok = Self::transaction_step(&mut self.commit_stmt);
    if !ok { Self::transaction_step(&mut self.rollback_stmt); }
    self.transaction = false;
    ok
}
```

Every method — `read()`, `create()`, `like()` — begins with `if !self.begin() { return error(...500...) }`. **Reads too.** Why? Quote from the README: "Live reads share a deferred SQLite transaction through each serialized completion batch. Writes upgrade it as needed, avoiding repeated pager setup while keeping every query live." A plain `BEGIN` (deferred) does not take the write lock; the first `INSERT` in the batch upgrades it to write. The gain measured in `IO_URING.md`: feed +23 %, single post +28 %, because SQLite does not do `fstat`/pager setup per query ("3.001 versus 1.000 file-stat calls per read-only feed request").

The checkpoint is off the response path and driven by a frame counter from `sqlite3_wal_hook`:

```rust
unsafe extern "C" fn wal_hook(data: *mut c_void, _: *mut Connection, _: *const c_char, frames: i32) -> i32 {
    unsafe { (*data.cast::<Cell<i32>>()).set(frames); }
    0
}
pub fn checkpoint(&mut self) {
    if self.wal_frames.get() >= 1000 {
        let rc = unsafe { sqlite3_wal_checkpoint_v2(self.raw, ptr::null(), 2 /* RESTART */, ...) };
        if rc == 0 { self.wal_frames.set(0); }
    }
}
```

`PRAGMA wal_autocheckpoint=0` disables the automatic checkpoint in the middle of `COMMIT`; the loop calls `checkpoint()` *after* `flush()`, so clients get their responses before SQLite starts copying the WAL back into the main file.

### 2.2 Waking clients without blocking the loop: `Pending` + `flush`

There are no channels here. At the moment a request is handled, `process()` writes the response into the connection's buffer and remembers *where*:

```rust
struct Pending { fd: usize, generation: u32, start: u32, count: u32, interim: bool }

fn dirty(&mut self, fd: usize) -> usize {
    let c = &mut self.clients[fd];
    if c.state & DIRTY != 0 { return (c.state >> INDEX_SHIFT) as usize; }   // already in pending
    let index = self.pending.len();
    self.pending.push(Pending { fd, generation: c.generation, start: c.output.len, count: 0, interim: false });
    c.state |= DIRTY | ((index as u32) << INDEX_SHIFT);   // index into pending stuffed into the upper bits of state
    index
}
```

After `commit()` the loop calls `flush(committed)`:

```rust
fn flush(&mut self, committed: bool) {
    if !committed {
        // COMMIT failed: roll every output back to `start` and write as many 500 responses as there were requests
        self.body.clear();
        error(&mut self.body, 500, "internal server error");
        for p in &self.pending {
            let c = &mut self.clients[p.fd];
            if c.generation != p.generation || c.state & LIVE == 0 { continue; }
            c.output.len = p.start;
            for i in 0..p.count {
                response(500, &self.body, c.state & CLOSING != 0 && i + 1 == p.count, &mut c.output);
            }
            if p.interim { c.output.extend(b"HTTP/1.1 100 Continue\r\n\r\n"); }
        }
    }
    for i in 0..self.pending.len() {
        let fd = self.pending[i].fd;
        let c = &mut self.clients[fd];
        if c.generation != self.pending[i].generation { continue; }
        c.state &= FLAG_MASK & !DIRTY;
        if c.state & LIVE == 0 || c.state & SENDING != 0 { continue; }   // previous send still in flight
        if c.output.len != 0 {
            c.flight = std::mem::take(&mut c.output);                     // move ownership of the buffer
            c.sent = 0;
            self.send(fd);                                               // a single send SQE
        } else if c.state & CLOSING != 0 { self.close(fd); }
    }
    self.pending.clear();
}
```

Two properties of this solution are hard to obtain in the async model:

1. **HTTP pipelining is preserved on failure.** When a client sent 3 requests in one packet and the COMMIT failed, responses 1–3 are replaced with 3 × 500 *in the same order*, because `Pending.count` remembers how many frames were in that range of the buffer.
2. **A read that "saw" an uncommitted write also waits.** Because reads share the transaction, a feed served after an `INSERT` in the same batch contains the new post. If the feed response went out and the COMMIT failed, the client would see data that never existed. `flush` after `commit` handles this automatically: *nothing* goes out before COMMIT.

### 2.3 The Axum #1 version (tbsvttr): an actor on a single Tokio thread + `yield_now` as the timer

```rust
// rust-axum-tbsvttr/src/main.rs
async fn work(mut self, mut queue: mpsc::Receiver<Job>) {
    let mut replies = Vec::with_capacity(256);
    while let Some(first) = queue.recv().await {
        tokio::task::yield_now().await; // Batch ready requests without a timer.
        let mut next = Some(first);
        while let Some(job) = next {
            let result = self.handle(&job).unwrap_or_else(|_| failure(500, "internal server error"));
            if self.transaction && self.db.is_autocommit() { self.failed = true; }   // SQLite rolled back on its own
            replies.push((job.done, result));
            next = if replies.len() < 256 { queue.try_recv().ok() } else { None };
        }
        if self.transaction {
            if !self.failed { self.failed = self.db.execute_batch("COMMIT").is_err(); }
            if self.failed {
                let _ = self.db.execute_batch("ROLLBACK");
                assert!(self.db.is_autocommit(), "unable to roll back failed batch");
            }
        }
        for (done, result) in replies.drain(..) {
            let _ = done.send(if self.failed { failure(500, "internal server error") } else { result });
        }
        self.transaction = false;
        self.failed = false;
    }
}
```

The clever element: `tokio::task::yield_now().await` after the first job. The runtime is `current_thread`, so `yield_now` hands the floor to *all* the hyper tasks that have just received data from epoll; they push their `Job`s into the channel, and the actor collects them with `try_recv()` — no timer, no extra latency when there is no traffic. `begin()` does `BEGIN IMMEDIATE` only on the first write. Responses go back through `oneshot::Sender<Reply>` — every hyper handler waits in `result.await`.

The cost compared to `io_uring`: per request a `Job` (3 Strings + Vec), a `oneshot` (`Arc` allocation), a trip through `mpsc` (atomics + wakeup), and the response is copied once more into `Body`. But **the model is the same**: one owner of the SQLite connection, a batch of requests ready "now", one COMMIT, and only then waking the clients.

### 2.4 The Axum #2 version (SvetlinZarev): separate writer thread, reads in parallel

```rust
// rust-axum-SvetlinZarev/src/db.rs
pub fn writer_loop(path: String, mut rx: mpsc::Receiver<Write>) {
    let conn = open_conn(&path, false);
    let mut stmts = WriteStmts::new(&conn);                 // prepared once, live the whole time
    let mut batch: Vec<Write> = Vec::with_capacity(MAX_BATCH);   // 32
    while let Some(first) = rx.blocking_recv() {
        batch.push(first);
        while batch.len() < MAX_BATCH {
            match rx.try_recv() { Ok(req) => batch.push(req), Err(_) => break }
        }
        commit_batch(&conn, &mut stmts, &mut batch);
        if rx.is_empty() || last_checkpoint.elapsed() >= CHECKPOINT_INTERVAL { maybe_checkpoint(&conn); ... }
    }
}
```

`commit_batch` does `BEGIN` → all `INSERT`s → `COMMIT`; on error, `ROLLBACK` and `retry_individually` (each write separately, so one bad operation does not sink its neighbors). Reads go through `thread_local! READ_CONN` — a separate read-only connection per Tokio thread (`with_read(|conn| ...)`). This is the classic "single writer, N readers" pattern for WAL. Its weakness on 1 vCPU: the writer is an **extra thread**, so every write costs two context switches (Tokio → writer → Tokio) and there is no sharing of the transaction with reads.

### 2.5 How C++ and Zig did it

* C++ (`server.cpp`): `commit_group()` called after handling a batch of CQEs **or** when `deferred_count_ == kMaxDeferred`; before that, `io_uring_submit_and_wait_timeout(..., busy ? 128 : 1, busy ? 6 ms : idle)`. The author measured CPU per request as a function of batch size: "25 us with no batching, 21 us at 1.5 ms, 18 us at 3 ms, 16.7 us at 6 ms, 15.6 us at 12 ms. 6 ms is where it flattens" — and paid for it with p99 ≈ 7 ms instead of < 1 ms. Rust chose 32 CQEs / 250 µs — smaller batches, lower latency.
* Zig (`main.zig`): `deliver()` appends the response to a global `pending: ArrayList(Pending)`; `afterLoop` (the uSockets callback after every loop iteration) calls `flush()`, which does the COMMIT and only then `us_socket_write`. `if (pending.items.len >= 256) flush();` — the identical limit as in Axum #1.

**The common denominator of all four:** the batch boundary is *an event loop iteration*, not a timer. A timer always adds latency; a loop iteration adds it only when there is actually something to group.

---

## 3. Zero-allocation, HTTP parsing, crypto and JSON straight from SQLite

The author of the winning code has a test (`tests/support/allocations.rs`, run with `cargo test --release -- --ignored`) that counts allocator calls during 100 warmed-up requests on each of the 5 endpoints and **expects zero**. Let's see how it achieves that.

### 3.1 Buffers: everything is an `extend` into an existing `Vec<u8>`/`Buffer`

The hot path operates on three reused buffers:

* `Worker.body: Vec<u8>` (16 KB) — the response body built by `App::serve(&req, &mut self.body)`,
* `Client.output: Buffer` — taken from `Worker.pool` (`self.pool.pop().unwrap_or_default()`), returned after send,
* `Db.feed_scratch: Vec<u8>` — a buffer for feed rows before reordering.

```rust
// src/uring.rs
fn response(status: u16, body: &[u8], close: bool, out: &mut Buffer) {
    out.extend(match status {
        200 => b"HTTP/1.1 200 OK\r\n",
        201 => b"HTTP/1.1 201 Created\r\n",
        400 => b"HTTP/1.1 400 Bad Request\r\n",
        401 => b"HTTP/1.1 401 Unauthorized\r\n",
        404 => b"HTTP/1.1 404 Not Found\r\n",
        503 => b"HTTP/1.1 503 Service Unavailable\r\n",
        _ => b"HTTP/1.1 500 Internal Server Error\r\n",
    });
    out.extend(b"Content-Type: application/json\r\nContent-Length: ");
    out.extend(itoa::Buffer::new().format(body.len()).as_bytes());   // itoa: number -> bytes on the stack
    out.extend(if close { b"\r\nConnection: close\r\n\r\n" } else { b"\r\n\r\n" });
    out.extend(body);
}
```

There is no `format!`, no `String`, no `HeaderMap`. The status is a `u16`, and the `match` on byte constants compiles to a pointer table.

### 3.2 HTTP parsing: `httparse` + borrows, zero copying

```rust
// src/main.rs
pub struct Frame<'a> {
    method: &'a str, path: &'a str,
    authorization: Option<&'a str>,
    body: Cow<'a, [u8]>,          // Borrowed for Content-Length, Owned only for chunked (rare)
    pub consumed: usize, pub close: bool,
}
pub fn frame(input: &[u8]) -> Result<Parsed<'_>, ()> {
    let mut headers = [httparse::EMPTY_HEADER; 64];      // 64 x 32 B on the STACK
    let mut req = httparse::Request::new(&mut headers);
    let end = match req.parse(input).map_err(|_| ())? {
        httparse::Status::Partial => return Ok(Parsed::Incomplete { expect_continue: false }),
        httparse::Status::Complete(n) => n,
    };
    for h in req.headers.iter() {
        if h.name.eq_ignore_ascii_case("authorization") { authorization = Some(from_utf8(h.value)?); }
        else if h.name.eq_ignore_ascii_case("content-length") { ... }
        else if h.name.eq_ignore_ascii_case("connection") { close |= h.value.split(|&c| c == b',').any(|v| v.trim_ascii().eq_ignore_ascii_case(b"close")); }
        ...
    }
    ...
}
```

`Frame<'a>` lives as long as the read buffer from the kernel (`bytes` in `on_recv` is `from_raw_parts` on a provided buffer). Nothing is copied into a `String`. For comparison, Axum: hyper parses into an `http::Request` with a `HeaderMap` (a hash map with allocated `HeaderValue`s), and then the author copies into `Job { method: String, path: String, auth: String }` anyway.

C++ went a step further (SSE2 header scan 16 bytes at a time: "A `GET` parses in about 35 ns vs 70-80 for `memmem`/`memchr`"), but in the Rust profile HTTP parsing is not visible — so `httparse` is enough.

### 3.3 Crypto: HMAC with a precomputed key, signature on the stack

```rust
// src/main.rs
struct Auth { mac: Hmac<Sha256>, header: Vec<u8>, payload: Vec<u8> }   // reused buffers

fn user(&mut self, authorization: Option<&str>) -> Result<(i64, Cow<'_, str>), &'static str> {
    let token = authorization.and_then(|a| a.strip_prefix("Bearer ")).ok_or("missing bearer token")?;
    let mut pieces = token.split('.');
    let (h, p, s) = (pieces.next()?, pieces.next()?, pieces.next()?);
    let mut sig = [0u8; 33];                                        // 32 B of signature + slack, on the stack
    let n = URL_SAFE_NO_PAD.decode_slice(s, &mut sig).map_err(|_| bad)?;
    let mut mac = self.mac.clone();                                 // clone of the state after ipad: ~100 B memcpy, 0 allocations
    mac.update(&token.as_bytes()[..h.len() + 1 + p.len()]);        // we sign the raw bytes "header.payload"
    mac.verify_slice(&sig[..n]).map_err(|_| bad)?;                  // constant-time comparison
    self.header.clear();
    URL_SAFE_NO_PAD.decode_vec(h, &mut self.header).map_err(|_| bad)?;   // decode INTO the existing Vec
    let header: Header = serde_json::from_slice(&self.header).map_err(|_| bad)?;   // Cow<str> borrowed
    if header.alg != "HS256" { return Err(bad); }
    self.payload.clear();
    URL_SAFE_NO_PAD.decode_vec(p, &mut self.payload).map_err(|_| bad)?;
    let claims: Claims = serde_json::from_slice(&self.payload).map_err(|_| bad)?;
    ...
}
```

The order is deliberate: **signature first, JSON second**. A token with a bad signature never reaches the JSON parser (resistance to abuse and less work). `Hmac::new_from_slice` is called once in `Auth::new`; `clone()` copies the processed key block (`ipad`/`opad`). C++ does exactly the same by hand: `SHA256_Init(&inner_); SHA256_Update(&inner_, pad, 64)` in the `JwtVerifier` constructor, and `verify` copies the `SHA256_CTX` — "a request costs two short hash continuations".

Claims are read as borrows, without `serde_json::Value`:

```rust
#[derive(Deserialize)]
struct Claims<'a> {
    #[serde(borrow)] sub: Option<&'a serde_json::value::RawValue>,   // raw JSON slice, 0 allocations
    #[serde(borrow)] username: Option<&'a serde_json::value::RawValue>,
    exp: Option<f64>,
    nbf: Option<f64>,
}
```

Compare Axum #1: `let parts: Vec<_> = token.split('.').collect(); let mut decoded = Vec::with_capacity(3); ... decoded.push(URL_SAFE_NO_PAD.decode(part)?)` + `let claims: Value = serde_json::from_slice(&decoded[1])` + `Hmac::new_from_slice(&self.secret)` *per request* — about 10 allocations and re-processing the key for every token.

### 3.4 Input JSON: a visitor that reads only `body`

Instead of `serde_json::Value` (a tree, `Map<String, Value>` = allocations per key) the author wrote a `DeserializeSeed` that walks the whole document (full validation, because the spec requires 400 for bad JSON) but remembers a single string:

```rust
#[derive(Clone, Copy)]
enum BodySeed { Root, String, Ignore }
impl<'de> serde::de::Visitor<'de> for BodySeed {
    type Value = Option<Cow<'de, str>>;
    fn visit_borrowed_str<E>(self, s: &'de str) -> Result<Self::Value, E> {
        Ok(matches!(self, Self::String).then_some(Cow::Borrowed(s)))   // no escapes: a borrow from the buffer
    }
    fn visit_str<E>(self, s: &str) -> Result<Self::Value, E> {          // with escapes: serde decoded into a temporary
        Ok(if matches!(self, Self::String) { Some(Cow::Owned(s.to_owned())) } else { None })
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut body = None;
        if matches!(self, Self::Root) {
            while let Some(Text(key)) = map.next_key::<Text<'de>>()? {
                let value = map.next_value_seed(if key == "body" { Self::String } else { Self::Ignore })?;
                if key == "body" { body = value; }
            }
        } else { while map.next_key_seed(Self::Ignore)?.is_some() { map.next_value_seed(Self::Ignore)?; } }
        Ok(body)
    }
    // visit_seq / visit_i64 / ... return None — but being called means serde has validated the token
}
```

### 3.5 Output JSON "straight from SQLite"

There is no `json_object()` in SQL here (C++ and Rust both concluded that the cost of SQLite building the JSON is higher than a custom writer — the profile showed the SQLite interpreter is the bottleneck, not escaping). Instead: **raw column bytes → escaping → output buffer**, with no `String` along the way:

```rust
// src/db.rs
pub fn text(&self, col: i32) -> &[u8] {
    // SQLite guarantees the pointer until this statement is stepped/reset/finalized.
    // Borrowing self prevents those operations while the returned slice is live.
    unsafe {
        let p = sqlite3_column_text(self.0, col);
        let len = sqlite3_column_bytes(self.0, col);
        if p.is_null() { &[] } else { slice::from_raw_parts(p, len as usize) }
    }
}
fn append_post_with_likes(stmt: &Stmt, likes: u64, out: &mut Vec<u8>) {
    out.extend_from_slice(b"{\"id\":");          crate::number(stmt.int(0) as u64, out);
    out.extend_from_slice(b",\"body\":");        crate::json_string(stmt.text(1), out);   // &[u8] from SQLite -> escape -> out
    out.extend_from_slice(b",\"created_at\":");  crate::json_string(stmt.text(2), out);
    out.extend_from_slice(b",\"author\":");      crate::json_string(stmt.text(3), out);
    out.extend_from_slice(b",\"like_count\":");  crate::number(likes, out);
    out.push(b'}');
}
```

and `json_string` has a SIMD fast path for pure ASCII:

```rust
// src/main.rs — 16 bytes at a time: is there a `"`, `\` or a byte < 0x20 here?
#[inline]
fn plain16(b: &[u8]) -> bool {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        use std::arch::x86_64::*;
        let v = _mm_loadu_si128(b.as_ptr().cast());
        let bad = _mm_or_si128(
            _mm_or_si128(_mm_cmpeq_epi8(v, _mm_set1_epi8(34)), _mm_cmpeq_epi8(v, _mm_set1_epi8(92))),
            _mm_cmpeq_epi8(_mm_min_epu8(v, _mm_set1_epi8(31)), v),      // v <= 31  <=>  min(v,31) == v
        );
        _mm_movemask_epi8(bad) == 0
    }
    ...
}
pub fn json_string(b: &[u8], out: &mut Vec<u8>) {
    out.push(b'"');
    let (mut i, mut start) = (0, 0);
    while i < b.len() {
        if i + 16 <= b.len() && plain16(&b[i..]) { i += 16; continue; }   // 16 B without copying, without a branch per byte
        let c = b[i];
        if c < 32 || c == b'"' || c == b'\\' {
            out.extend_from_slice(&b[start..i]);        // copy the clean run in bulk
            match c { b'"' => out.extend_from_slice(b"\\\""), b'\\' => ..., b'\n' => ..., _ => /* \u00XX */ }
            start = i + 1;
        }
        i += 1;
    }
    out.extend_from_slice(&b[start..]);
    out.push(b'"');
}
```

Dart (`dart-rawsocket-C-Hatton`) has a faithful copy of this idea: `CAST(p.body AS BLOB)` in the SELECT, then `_Out.str(Uint8List)` with the same byte-by-byte escaping — "It took `GET /feed` from 13.5k to 23k req/s on one core (+70%)".

### 3.6 The feed as three range scans (`range_feed`)

The reference query (`SELECT ... (SELECT count(*) FROM likes l WHERE l.post_id=p.id) ... LIMIT 20`) is 20 `count(*)` subqueries through the index. The author noticed that the 20 newest posts usually have *almost contiguous* IDs:

```rust
// src/db.rs
fn range_feed(&mut self, out: &mut Vec<u8>) -> Option<u16> {
    let mut ids = [0i64; 20];                                   // on the stack
    // (1) SELECT id FROM posts ORDER BY created_at DESC,id DESC LIMIT 20
    ...
    if maximum.checked_sub(minimum)? >= 256 { return None; }   // IDs scattered -> regular query
    let mut slots = [-1i8; 256];                                // map id -> position in the feed, on the stack
    // (2) SELECT post_id FROM likes WHERE post_id BETWEEN ?1 AND ?2     -> one index scan, counting into likes[20]
    // (3) SELECT p.id,p.body,p.created_at,u.username FROM posts p JOIN users u ... WHERE p.id BETWEEN ?1 AND ?2
    //     -> rows into feed_scratch, and `segments[slot]` remembers (start,end) of each post
    // (4) assemble the response in the original order (created_at DESC, id DESC) by copying segments
    ...
}
```

Rule 5 (no cache) is preserved — every request discovers the IDs anew. This is not a "Rust trick", it is a "think about the query plan" trick: 3 sequential scans instead of 1 + 20 random lookups. C++ has the identical "Feed as three range scans".

---

## 4. Analysis of `unsafe` and `Cargo.toml`

### 4.1 The winner's `Cargo.toml`

```toml
[package]
name = "twelve-rust-poll"
edition = "2024"
build = "build.rs"
[features]
default = ["sqlite-pgo"]
sqlite-pgo = []
[dependencies]
io-uring = "=0.7.15"      # thin wrapper over io_uring syscalls, no executor
libc = "=0.2.183"
httparse = "=1.10.1"      # allocation-free HTTP/1 parser (headers on the stack)
memchr = "=2.8.0"         # SIMD memmem for chunked encoding
serde = { version = "=1.0.228", features = ["derive"] }
serde_json = { version = "=1.0.149", features = ["raw_value"] }   # RawValue = borrowing JSON fragments
itoa = "=1.0.18"          # int -> bytes without fmt
base64 = "=0.22.1"
sha2 = "=0.10.9"
hmac = "=0.12.1"
[build-dependencies]
cc = "=1.2.56"            # compiles vendor/sqlite3.c
[profile.release]
opt-level = 3
lto = "fat"               # one LLVM module: inlining across crate boundaries (serde, httparse, io-uring)
codegen-units = 1         # no splitting into units: better optimization, longer compile
panic = "abort"           # no unwind tables, smaller code, no landing-pad costs
strip = true
```

Plus `build.sh`: `export RUSTFLAGS="-C target-cpu=native"` (SSE4/AVX2 for the entire binary) and a `build.rs` compiling SQLite with:

```rust
.define("SQLITE_THREADSAFE", "0")          // zero mutexes in SQLite — serialization is on the Rust side (Mutex<App>)
.define("SQLITE_DEFAULT_MEMSTATUS", "0")   // no global memory counter (atomics per malloc)
.define("SQLITE_DQS", "0")
.define("SQLITE_OMIT_LOAD_EXTENSION", None)
.define("SQLITE_OMIT_DEPRECATED", None)
.define("SQLITE_OMIT_SHARED_CACHE", None)
.define("SQLITE_OMIT_PROGRESS_CALLBACK", None)
.define("SQLITE_LIKE_DOESNT_MATCH_BLOBS", None)
.define("SQLITE_USE_ALLOCA", None)
```

plus SQLite PGO: `build.rs` builds `bench/train_sqlite.c` with `-fprofile-generate`, runs it on a synthetic database and recompiles `sqlite3.c` with `-fprofile-use`. C++ measured the effect: "feed 11.6 us vs 16.3 for Ubuntu's 3.45.1, post lookup 3.7 vs 4.5" (−30 %). This is the largest single gain you can get *without touching your own code* — because 50–60 % of the profile is the SQLite interpreter.

For comparison, Axum #1 has an identical release profile (`lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = true`) and also its own SQLite 3.53.4 linked statically — so *the compiler profile alone does not explain the 43k vs 64k difference*. Axum #2 has `lto = "thin"` and `tikv-jemallocator` (jemalloc reduces fragmentation and returns memory — a sensible choice when you allocate a lot per request).

### 4.2 Where and why `unsafe` is used — and what could be replaced

In `uring.rs`, `db.rs`, `main.rs`, `net.rs` there are ~45 `unsafe` blocks. Grouped:

| # | Category | Example | Performance gain | Safe replacement |
|---|---|---|---|---|
| 1 | **FFI to SQLite** (`db.rs`: `extern "C"`, `sqlite3_step`, `sqlite3_column_text`, `sqlite3_bind_text` with `SQLITE_STATIC`) | `Stmt::text()` returns a `&[u8]` borrowed from SQLite | **Key.** Zero column copies; `SQLITE_STATIC` on bind means `body` is not copied into SQLite. Does `rusqlite` use `SQLITE_TRANSIENT` for `&str`? No — rusqlite also binds `&str` as `SQLITE_STATIC` and returns a borrowed `ValueRef<'_>`; the difference versus rusqlite is mainly no `Result` per column, no statement cache (hash lookup) and `SQLITE_THREADSAFE=0` | `rusqlite` with `prepare_cached` and `ValueRef::as_bytes()` gives ~95 % of this performance. The author chose his own bindings to control the SQLite compilation and have 0 "heavy" dependencies |
| 2 | **Submitting SQEs** (`uring.rs::queue`: `ring.submission().push(&entry)`) | — | Forced by the `io-uring` crate: `push` is `unsafe` because an SQE contains raw pointers whose lifetime is managed by the user | None (it is the library's contract). The alternative `tokio-uring`/`monoio` gives a safe API at the cost of an executor and buffer ownership (`Vec<u8>` moved into the operation — allocations) |
| 3 | **Custom `Buffer` with `alloc/realloc/dealloc`** (`uring.rs`) | `#[repr(C)] struct Buffer { ptr, len: u32, cap: u32 }` | Moderate. 16 B instead of 24 B for `Vec<u8>` lets `Client` fit in 64 B (one cache line; 64,000 × 64 B = 4 MB). The stable address during `send` is ensured anyway by forbidding `reserve` on `flight` | `Vec<u8>` + `Client` 88 B. At 64k connections that is +1.5 MB and some clients on two cache lines. The author did not measure separately; in the profile at 365k users "kernel established-connection lookup" dominates LLC-misses, not the Client structure. **Verdict: replaceable without measurable loss** below ~100k connections |
| 4 | **`mmap` for provided buffers** (`Mapping`) | `libc::mmap(MAP_PRIVATE \| MAP_ANONYMOUS)` | Page alignment needed for `register_buf_ring` | `std::alloc::alloc(Layout::from_size_align(n, 4096))` — also `unsafe`. Safe crates (`memmap2::MmapMut::map_anon`) remove `unsafe` from your code at no cost |
| 5 | **Buffer publication** (`recycle`, `publish_buffers`: writing `BufRingEntry` and `AtomicU16::store(tail, Release)`) | — | Key to the "0 B per idle connection" model | No safe equivalent in `io-uring 0.7`; this is a shared-memory protocol with the kernel |
| 6 | **`from_raw_parts` on the read buffer** (`on_recv`) | `slice::from_raw_parts(recv_memory.ptr.add(bid * BUFSIZE), result)` | Key: zero copies from the kernel buffer to the parser | You can make `recv_memory` a `&mut [u8]` from `Mapping` once and index `&buf[bid*BUFSIZE..][..result]` — a safe slice with no difference in machine code |
| 7 | **SIMD `plain16`** (`main.rs`) | `_mm_loadu_si128` | Small. Profile: JSON escaping ≈ 3.9–4.2 % of the feed. The author tested AVX2 intrinsics and hand-written assembler — "neither scanner is shipped" (1–3 % regression on short strings) | A scalar loop `b[..16].iter().all(|&c| c >= 32 && c != b'"' && c != b'\\')` — LLVM often auto-vectorizes; loss < 1 % overall. Or `std::simd` (nightly) |
| 8 | **`unsafe impl Send for App`** | raw pointers `*mut Connection` in `Db` | Zero performance impact; this only appeases the compiler, because `App` is moved between threads under a `Mutex` | Newtype `struct Conn(*mut Connection); unsafe impl Send for Conn {}` with a comment — still `unsafe`, but confined to 1 line. Or `rusqlite::Connection`, which is `Send` |
| 9 | **`libc::getrlimit/setrlimit/setsockopt/listen`** (`uring.rs::run`) | TCP_NODELAY, backlog 4096, raising the soft limit | Zero in the hot path (once at startup) | `socket2::Socket::set_nodelay`, the `rlimit` crate — **replace without hesitation** |
| 10 | **All of `net.rs` (epoll via `libc`)** | `epoll_wait`, `accept4`, `recv`, `send` | Comparison path (`--epoll`), not production | `mio` gives the same thing safely; the difference is unmeasurable |
| 11 | **`wal_hook` callback and `Box<Cell<i32>>`** (`db.rs`) | pointer to a `Cell` passed to C | Checkpoint off the response path | `rusqlite` does not expose `sqlite3_wal_hook`; the alternative `PRAGMA wal_checkpoint(PASSIVE)` every N commits (as in Axum #2) — safe, ~the same effect |

**Summary:** the `unsafe` that really buys performance is **1, 5, 6** (zero-copy between the kernel, the parser and SQLite) and indirectly **2, 4** (imposed by io_uring). Items **3, 7, 8, 9, 10, 11** can be replaced with safe Rust or proven crates without measurable loss — and that is what I would do in production code. The author himself writes in the README: "Unsafe code covers C bindings, Linux I/O, vector loads and compact owning buffers" — and documented the invariants at every block (this is a pattern to copy: **every `unsafe` has a "why this is correct" comment**).

### 4.3 What to learn from `IO_URING.md` (methodology)

This file is as valuable as the code:

* **Profile before optimizing.** "feed flat samples put 24.36% in SQLite's interpreter, 8.37% in table lookup and 3.87% in JSON escaping … SQLite transaction setup therefore offers a larger target than a JSON-only assembly rewrite." — and indeed: the deferred read transaction gave +23 %, and hand-written AVX2 gave nothing.
* **Balanced order (AB/BA) and medians**, not single runs; reporting ranges; admitting that "clock variation prevents a guarantee that every run improves".
* **Rejected experiments are documented**: branchless, unchecked indexing (`get_unchecked`) — "Feed medians were 1.52% and 0.61% below control" → they did not go in. Lesson: `unsafe` to skip bounds checks did *not* yield a gain, because LLVM removes most of the checks in loops with a known range anyway.
* Bitwise `|` instead of `||` in the JSON predicate: "release executable is byte-for-byte identical to control" — the compiler had already done it.

---

## 5. Practical cheat sheet: production Rust (80 % of the gain for 20 % of the effort)

You do not have to write your own HTTP server. Five patterns from this repository that carry over 1:1 to Axum/Tokio:

### 5.1 One owner of the database + group commit per "tick"

**Typical, slow code:**

```rust
// Connection pool, every handler opens its own transaction => 1 fsync per write, SQLITE_BUSY under load
async fn like(State(pool): State<Pool>, Path(id): Path<i64>, user: User) -> impl IntoResponse {
    let conn = pool.get().await?;
    conn.execute("INSERT INTO likes(user_id,post_id) VALUES(?,?) ON CONFLICT DO NOTHING", params![user.id, id])?;
    StatusCode::CREATED
}
```

**12-Dollar-Server style (Axum #1 + the `Pending` idea):**

```rust
enum Write { Like { user: i64, post: i64, done: oneshot::Sender<Result<bool>> }, Create { ... } }

async fn like(State(tx): State<mpsc::Sender<Write>>, Path(id): Path<i64>, user: User) -> impl IntoResponse {
    let (done, rx) = oneshot::channel();
    tx.send(Write::Like { user: user.id, post: id, done }).await.ok();
    match rx.await { Ok(Ok(true)) => StatusCode::CREATED, Ok(Ok(false)) => StatusCode::OK, _ => StatusCode::INTERNAL_SERVER_ERROR }
}

fn writer(conn: Connection, mut rx: mpsc::Receiver<Write>) {         // std::thread or tokio::spawn on current_thread
    let mut like = conn.prepare("INSERT INTO likes ... ON CONFLICT DO NOTHING").unwrap();   // prepared ONCE
    let mut batch = Vec::with_capacity(256);
    while let Some(first) = rx.blocking_recv() {
        batch.push(first);
        while batch.len() < 256 { match rx.try_recv() { Ok(w) => batch.push(w), Err(_) => break } }   // collect what is already waiting
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        let results: Vec<_> = batch.iter().map(|w| apply(&mut like, w)).collect();
        let committed = conn.execute_batch("COMMIT").is_ok();
        for (w, r) in batch.drain(..).zip(results) {
            let _ = w.done().send(if committed { r } else { Err(anyhow!("commit failed")) });   // response ONLY after COMMIT
        }
    }
}
```

Rules: `wal_autocheckpoint=0` + your own `PRAGMA wal_checkpoint(PASSIVE)` between batches; `BEGIN IMMEDIATE` (write lock right away, no escalation in the middle); response sent *after* `COMMIT`; on error — the whole batch gets an error or retry individually (Axum #2).

### 5.2 Borrow, don't copy: `&str`/`&[u8]`/`Cow`/`RawValue` in request structures

**Slow:**

```rust
#[derive(Deserialize)]
struct Claims { sub: String, username: String, exp: f64 }            // 2 String allocations
let v: serde_json::Value = serde_json::from_slice(&body)?;           // tree: Map + String per key
let text = v["body"].as_str().unwrap_or("").to_owned();              // another copy
```

**Fast:**

```rust
#[derive(Deserialize)]
struct Claims<'a> {
    #[serde(borrow)] sub: Cow<'a, str>,                              // a borrow when there are no escapes
    #[serde(borrow)] username: Cow<'a, str>,
    exp: f64,
}
#[derive(Deserialize)]
struct CreatePost<'a> { #[serde(borrow)] body: Cow<'a, str> }         // only the needed field
let req: CreatePost = serde_json::from_slice(&body_bytes)?;          // body_bytes: axum::body::Bytes
```

In Axum, receive the body as `Bytes` (not `Json<T>` with owned fields, not `String`) and deserialize with borrows. Build the response into a `Vec<u8>` and return it as `Body::from(vec)` — `serde_json::to_vec` instead of `to_string` + `.into()`.

### 5.3 Prepared statements kept in a struct, columns read as bytes

**Slow:**

```rust
let mut stmt = conn.prepare("SELECT ...")?;                           // SQL compilation per request
let posts: Vec<Post> = stmt.query_map([], |r| Ok(Post { body: r.get(1)?, .. }))?.collect()?;   // String per column
let json = serde_json::to_vec(&Feed { posts })?;                     // second serialization
```

**Fast (rusqlite, no `unsafe`):**

```rust
struct Db { conn: Connection, feed: Statement<'static> /* via self_cell/ouroboros */ }   // or conn.prepare_cached(SQL) with a large cache capacity
let mut rows = self.feed.query([])?;
out.extend_from_slice(b"{\"posts\":[");
while let Some(row) = rows.next()? {
    let body: &[u8] = row.get_ref(1)?.as_bytes()?;                   // ValueRef<'_>: a borrow, 0 copies
    out.extend_from_slice(b"{\"id\":"); write_int(row.get::<_, i64>(0)?, &mut out);
    out.extend_from_slice(b",\"body\":"); write_json_string(body, &mut out);   // your escaping function (see 3.5)
    ...
}
out.extend_from_slice(b"]}");
```

`prepare_cached` + `set_prepared_statement_cache_capacity(N)` is 1 line and −30 % SQLite CPU in a typical service. Reading `ValueRef::as_bytes()` instead of `String` is another −20 % on list endpoints.

### 5.4 Reuse buffers per task/thread; `itoa`, `write!` into `Vec<u8>` instead of `format!`

**Slow:**

```rust
let header = format!("HTTP/1.1 {} OK\r\nContent-Length: {}\r\n\r\n", status, len);   // String + fmt
let body = format!("{{\"liked\":true,\"post_id\":{}}}", id);
```

**Fast:**

```rust
thread_local! { static OUT: RefCell<Vec<u8>> = RefCell::new(Vec::with_capacity(16 * 1024)); }
OUT.with(|b| {
    let mut out = b.borrow_mut(); out.clear();
    out.extend_from_slice(b"{\"liked\":true,\"post_id\":");
    out.extend_from_slice(itoa::Buffer::new().format(id).as_bytes());
    out.push(b'}');
    // copy into Bytes once (Bytes::copy_from_slice) — or keep a pool of Vecs like `Worker.pool`
});
```

In Tokio `thread_local!` works because a task does not switch threads *in the middle of* a synchronous section. Do not hold the borrow across an `.await`.

### 5.5 Measure and configure: SQLite pragmas, release profile, `target-cpu`, load-driven batching

```sql
PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;          -- 1 fsync per commit instead of 2
PRAGMA locking_mode=EXCLUSIVE;                               -- (single process only!) no fcntl shm-lock per read
PRAGMA mmap_size=1073741824; PRAGMA cache_size=500;          -- read from the OS page cache, don't duplicate it in SQLite
PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=0;       -- do the checkpoint yourself, off the response path
```

```toml
[profile.release]
lto = "fat"; codegen-units = 1; panic = "abort"; strip = true
# + RUSTFLAGS="-C target-cpu=native" if the binary runs on the machine it was built on
```

And the batching governor: under load wait for "a few events or a short timeout", when idle — for a single event. In Tokio the equivalent is `yield_now().await` after the first element (Axum #1) or `tokio::time::timeout(Duration::from_micros(250), rx.recv())` in the writer loop **only when** the previous batch had ≥ 4 elements.

### 5.6 The "slow vs fast" table in one place

| Area | Typical Rust | 12-Dollar-Server style | Expected gain |
|---|---|---|---|
| Transactions | autocommit per request, connection pool | 1 writer, `BEGIN IMMEDIATE`…`COMMIT` per batch, response after commit | 5–20× write throughput |
| SQL | `conn.prepare` per request | `Statement` in a struct / `prepare_cached` | −20–30 % SQLite CPU |
| Columns | `row.get::<String>` | `get_ref().as_bytes()` → custom writer | −50 % allocations on list endpoints |
| JSON out | struct → `serde_json::to_string` → `String` → `Body` | bytes into a reused `Vec<u8>`, `itoa` | 2–5× on serialization |
| JSON in | `serde_json::Value` | `#[serde(borrow)] Cow<'a, str>`, only the needed fields | 3–10× on parsing |
| JWT | `jsonwebtoken::decode` with `Validation` per request | `Hmac` with the key prepared once, `clone()` per token, signature before JSON | 2× on auth |
| Headers/formatting | `format!`, `HeaderMap::insert` | `extend_from_slice(b"...")`, `itoa` | small, but zero allocations |
| Memory per connection | default hyper buffers (8 KB+) | keep-alive limit (`Connection: close` above N), `http1::Builder::max_buf_size`, or io_uring provided buffers | ×10–20 less RSS with heavy keep-alive |
| WAL checkpoint | automatic (in the middle of COMMIT) | `wal_autocheckpoint=0` + PASSIVE between batches | stable write p99 |
| Build | default release | fat LTO, 1 CGU, abort, `target-cpu`, own SQLite with `THREADSAFE=0` + PGO | 10–30 % globally |

---

## 6. Three practical exercises (refactoring katas)

For each: clone the repo, `git fetch origin refs/pull/N/head:prN`, `git checkout prN`, work in `submissions/<...>`. Correctness tests: `bash test/run.sh submissions/<directory>` (42 checks). Local benchmark: `wrk`/`oha` on `/feed` and `/posts/:id`, or `k6 run -e VUS=2000 bench/load.js`.

### Kata 1 — Zero-alloc feed in Axum (PR #22, `rust-axum-SvetlinZarev`)

Goal: `GET /feed` without `Vec<Post>`, without a `String` per column and without `serde_json`.

1. In `src/db.rs` add a `ReadStmts` struct with a `Statement` for `SQL_FEED` and `SQL_POST_BY_ID` kept in `thread_local!` next to `READ_CONN` (or use `prepare_cached` and raise the cache capacity).
2. Move `json_string` and `number` from `rust-epoll-scooter1337/src/main.rs` (the scalar version, without SIMD) to `src/response.rs`.
3. Rewrite `api/feed.rs`: `let mut out = Vec::with_capacity(4096); out.extend_from_slice(b"{\"posts\":[");` → a `while let Some(row) = rows.next()?` loop with `row.get_ref(1)?.as_bytes()?` → `Response::builder().header(CONTENT_TYPE, "application/json").body(Body::from(out))`.
4. Remove `Post::from_row`, `FeedResponse`, `PostResponse`.
5. Measure `oha -c 100 -z 15s http://127.0.0.1:3000/feed` before and after; compare the number of allocations with `heaptrack` or `valgrind --tool=dhat` for 1000 requests. Goal: ≥ 1.5× req/s, < 5 allocations per request (hyper will do a few anyway).

### Kata 2 — Group commit "per tick" in Axum (PR #22)

Goal: change the writer in `db.rs` so that reads and writes from one iteration share a transaction and responses go out after COMMIT — as in `uring.rs::run` + `flush`.

1. Change the runtime to `#[tokio::main(flavor = "current_thread")]` and replace `std::thread::spawn(writer_loop)` with a Tokio task with `yield_now().await` after the first `recv` (model: `rust-axum-tbsvttr/src/main.rs::work`).
2. Extend `enum Write` with read variants (`Feed { done }`, `Post { id, done }`) and route *all* requests through the actor, so that they have one connection and one `BEGIN` (deferred) per batch. Start the transaction on the first query, not only on a write (the winner's `db.rs::begin`).
3. Add an equivalent of `Pending`: a vector of `(oneshot::Sender, Reply)` that sends the responses after `COMMIT`, and on error — 500 for all.
4. Add `PRAGMA wal_autocheckpoint=0` and `wal_checkpoint(PASSIVE)` after sending the responses, when `rx.is_empty()`.
5. Test: `python3 submissions/rust-axum-tbsvttr/tests/commit_check.py` (commit failure injection) must pass; `wrk -s submissions/rust-axum-tbsvttr/bench.lua` will show the req/s increase in a mix with writes. Bonus task: measure what happens to p99 when you use `sleep(1ms)` as the batching window instead of `yield_now`.

### Kata 3 — Slim down the connection: from 24 B to 16 B and back (PR #19, `rust-epoll-scooter1337`)

Goal: verify the thesis from 4.2 item 3 that `Buffer` can be replaced with `Vec<u8>` without measurable loss — and learn to measure before optimizing.

1. In `src/uring.rs` replace `struct Buffer` with `Vec<u8>` (`extend` → `extend_from_slice`, `consume` → `drain(..n)`, `reserve` stays). Remove `const _: () = assert!(size_of::<Client>() == 64)` and print the new size.
2. Preserve the invariant "`flight` does not grow while a send is in flight" — now it is enforced by `flight` never being `extend`-ed (add a `debug_assert!`).
3. Remove the `unsafe` from `Buffer::bytes/extend/consume/Drop` (about 6 blocks should disappear).
4. `cargo test --release -- --ignored --nocapture` with `CHECK_TOKEN` (the allocation test) must still report 0 allocations in the hot path.
5. Measure: `wrk -t2 -c64 -d20s` on `/feed` and `/posts/1` ×4 in AB/BA/BA/AB order (as in `IO_URING.md`); then `python3 tests/check.py --connections 80000` and compare RSS (`/proc/<pid>/status` → `VmRSS`). Write down the conclusions in the style of `IO_URING.md`: median, min–max, whether the difference exceeds the noise. Expected result: a difference within the noise for req/s, a few hundred KB difference in RSS at 80k connections.

---

## Appendix A — how to reproduce the analysis

```bash
git clone --depth 1 https://github.com/arjaythedev/twelve-dollar-server-challenge.git
cd twelve-dollar-server-challenge
git fetch --depth 1 origin 'refs/pull/*/head:refs/remotes/pr/*'
for pr in 19 17 22 32 25 46; do git ls-tree --name-only pr/$pr submissions/; done
git archive pr/19 submissions/rust-epoll-scooter1337 | tar -x -C /tmp/subs
```

## Appendix B — map of the winner's files

| File | What it contains | Most important functions |
|---|---|---|
| `src/uring.rs` | ring, worker, loop, buffers, backpressure, the 64-byte `Client` | `Worker::new`, `run`, `process`, `on_accept/on_recv/on_send`, `flush`, `response`, `tag` |
| `src/main.rs` | JSON writer (`json_string`, `plain16`), `Auth` (HS256), `frame` (HTTP), `BodySeed`, `App::serve` | `Auth::user`, `frame`, `App::serve` |
| `src/db.rs` | SQLite FFI, prepared statements, deferred transaction, checkpoint, `range_feed` | `Db::open`, `begin/commit/checkpoint`, `read`, `range_feed`, `create`, `like`, `append_post_with_likes` |
| `src/net.rs` | the epoll path (`--epoll`) with an arena buffer and the same `Pending` logic | `run` |
| `build.rs` | SQLite compilation with flags and PGO | — |
| `IO_URING.md`, `BENCHMARKS.md` | measurement methodology, `perf` profiles, rejected experiments | — |
