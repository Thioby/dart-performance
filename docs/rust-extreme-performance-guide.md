# Jak pisać ekstremalnie szybki kod w Rust — warsztat na bazie „Twelve Dollar Server Challenge”

> Źródło: https://github.com/arjaythedev/twelve-dollar-server-challenge
> Zgłoszenia nie są na `main`, tylko w otwartych PR-ach (`refs/pull/N/head`). Analizowane katalogi:
>
> | Zgłoszenie | PR | Pliki | Rola w tym przewodniku |
> |---|---|---|---|
> | `submissions/rust-epoll-scooter1337` | #19 | `src/uring.rs` (915 LOC), `src/net.rs` (437), `src/db.rs` (536), `src/main.rs` (491), `build.rs`, `Cargo.toml`, `IO_URING.md`, `BENCHMARKS.md` | **Zwycięzca** — Rust + surowy `io_uring` (nazwa katalogu „epoll” jest historyczna; ścieżka epoll została w `net.rs` jako wariant porównawczy `--epoll`) |
> | `submissions/rust-axum-tbsvttr` | #17 | `src/main.rs` (441 LOC), `Cargo.toml` | Rust #1 — Axum, 1 wątek Tokio (`current_thread`), aktor DB z group commit, bezpośrednio na porcie 80, odcina keep-alive powyżej 40 000 połączeń |
> | `submissions/rust-axum-SvetlinZarev` | #22 | `src/db.rs`, `src/api/*.rs`, `src/auth.rs` | Drugi Axum — za Nginx, osobny wątek writer + połączenia read-only per wątek, jemalloc |
> | `submissions/cpp-eastl-io_uring-pgo-hendy643` | #32 | `src/server.cpp`, `src/block_pool.hpp`, `src/conn.hpp`, `src/jwt.cpp`, `src/db.cpp` | C++ 64k — ten sam model co zwycięski Rust, z ciekawymi różnicami |
> | `submissions/zig-usockets-tbsvttr` | #25 | `src/main.zig`, `src/app.zig` | Zig 61k — uSockets + picohttpparser, group commit per iteracja pętli |
> | `submissions/dart-rawsocket-C-Hatton` | #46 | `bin/server.dart` | Dart — ten sam zestaw trików w Darcie (patrz przewodnik Dart) |
>
> Liczby „64k użytkowników, p99 224 ms, 52 % CPU, < 100 MB RAM” oraz „43k, 1.1 GB RAM” pochodzą z podsumowania benchmarku organizatora (Twoje streszczenie). W repozytorium autorzy mają własne pomiary — cytuję je, gdy pomagają zrozumieć *dlaczego*.

---

## 0. Model mentalny: skąd biorą się 64 000 połączeń na 1 vCPU

Zanim wejdziemy w kod, trzy liczby, które porządkują całą resztę:

1. **Budżet czasu.** k6 generuje dla 64k użytkowników ok. 40 000 req/s (każdy użytkownik „myśli” 3–15 s między żądaniami). Jeden vCPU ma 1 000 000 µs/s. Przy 52 % CPU wychodzi **~13 µs na żądanie** — wliczając jądro (TCP), parsowanie HTTP, HMAC-SHA256, SQLite i wysyłkę. Każda alokacja (~50–100 ns), każdy syscall (~0.5–1 µs), każde przełączenie kontekstu (~2–5 µs) to zauważalny ułamek tego budżetu.
2. **Budżet pamięci.** 64 000 połączeń w 100 MB to **~1.5 KB na połączenie** (razem z buforami jądra!). Jeżeli Twoja aplikacja trzyma per połączenie 16 KB bufora odczytu, zadanie Tokio i strukturę hyper, to 64k × ~20 KB = 1.3 GB — i to jest dokładnie historia Axuma.
3. **Budżet fsync.** Każdy `COMMIT` w WAL z `synchronous=NORMAL` to przynajmniej zapis do pliku WAL i cykl pager/lock. Przy ~1 000 zapisów/s (15 % lajków + 2 % postów) jeden COMMIT na *paczkę* zamiast na żądanie to różnica między „SQLite jest wąskim gardłem” a „SQLite to 4 % profilu”.

Zwycięska architektura minimalizuje wszystkie trzy jednocześnie: **jedna pętla zdarzeń na ring, zero alokacji per żądanie, jeden COMMIT per paczka ukończeń**.

---

## 1. Architektura I/O: `io_uring` vs Tokio/Axum

### 1.1 Jak zwycięzca konfiguruje `io_uring` (`src/uring.rs`)

Ring tworzony jest per wątek-worker, w `Worker::new`:

```rust
// src/uring.rs, Worker::new
let ring = IoUring::builder()
    .setup_cqsize(8192)          // kolejka ukończeń większa niż SQ (1024): paczki CQE
    .setup_coop_taskrun()        // jądro nie przerywa wątku IPI, dokończy pracę przy wejściu w syscall
    .setup_single_issuer()       // tylko ten wątek składa SQE -> jądro pomija locking
    .setup_defer_taskrun()       // praca "task_work" odkładana do następnego wejścia w io_uring_enter
    .build(1024)?;
ring.submitter().register_files_sparse(slots as u32)?;   // tablica deskryptorów *w ringu*, 65535 slotów
let recv_memory = Mapping::new(NBUFS * BUFSIZE)?;        // 1024 x 2048 B = 2 MB, mmap anonimowy
let descriptors = Mapping::new(NBUFS * size_of::<types::BufRingEntry>())?;
let registered = unsafe {
    ring.submitter().register_buf_ring_with_flags(descriptors.ptr.as_ptr() as u64, NBUFS as u16, GROUP, 0)
}.is_ok();
```

Cztery decyzje i ich sens:

| Flaga / wywołanie | Co robi | Dlaczego to ważne przy 64k połączeń |
|---|---|---|
| `SINGLE_ISSUER` + `DEFER_TASKRUN` + `COOP_TASKRUN` | Jądro zakłada, że jeden wątek obsługuje ring, i nie budzi go asynchronicznie; `task_work` (np. dostarczenie danych TCP do CQE) wykonuje się dopiero przy następnym `io_uring_enter` | Zamiast tysięcy wybudzeń na sekundę, pętla budzi się raz, zbiera *paczkę* ukończeń i obsługuje je hurtowo. To jest fundament group commit |
| `register_files_sparse(65535)` | Rejestruje pustą tablicę 65 535 „fixed files” wewnątrz ringu | Zaakceptowane gniazda lądują **w tej tablicy, a nie w tablicy FD procesu**. `LimitNOFILE=65535` przestaje być limitem liczby połączeń: 8 ringów × 65 535 = 524 280 slotów. Ponadto każde `recv`/`send` przez `types::Fixed(fd)` omija `fget()`/`fput()` (refcount na `struct file`) w jądrze |
| `register_buf_ring` (provided buffers) | 1024 buforów po 2 KB w jednym `mmap`, opisanych w pierścieniu, który jądro czyta samo | Multishot `recv` nie potrzebuje bufora *per połączenie*. 64 000 bezczynnych keep-alive **nie trzyma żadnego bufora odczytu** — jądro wybiera bufor dopiero, gdy przychodzą dane. To jest główny powód < 100 MB RSS |
| `setup_cqsize(8192)` | CQ większa niż SQ | Multishot accept/recv generują wiele CQE z jednego SQE; przepełnienie CQ (`-ENOBUFS`) byłoby katastrofą |

Operacje składane do ringu (wszystkie w `uring.rs`):

```rust
fn accept(&mut self) {
    self.accept_generation = self.accept_generation.wrapping_add(1);
    let e = opcode::AcceptMulti::new(types::Fd(self.listener))
        .allocate_file_index(true)                // jądro samo wybiera wolny slot w tablicy ringu
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

`user_data` to 64-bitowy tag kodujący operację, slot i **generację**:

```rust
fn tag(op: u64, fd: usize, generation: u32) -> u64 {
    op | ((fd as u64) << 8) | ((generation as u64) << 32)
}
```

Generacja rozwiązuje klasyczny problem pętli zdarzeń: połączenie w slocie 17 zostało zamknięte, slot 17 dostał nowego klienta, a z ringu wypada jeszcze stare CQE dla slotu 17. `on_recv`/`on_send` sprawdzają `self.clients[fd].generation == generation` i ignorują zombie. Ten sam trik jest w C++ (`conn_tag(op, gen, fd)` w `server.cpp`).

### 1.2 Pętla zdarzeń krok po kroku (`Worker::run`)

```rust
fn run(mut self, shared: Arc<Mutex<App>>) -> ! {
    let mut last_count = 0;
    loop {
        // (1) Ile ukończeń czekać i jak długo? Pod obciążeniem: do 32 CQE lub 250 µs.
        //     Bezczynnie: 1 CQE, do 2 s. To "regulator" batchingu.
        let timeout = if last_count >= 4 { Timespec::new().nsec(self.tuning.wait_us * 1000) }
                      else { Timespec::new().sec(2) };
        let wait = if !self.ready.is_empty() { 0 }
                   else if last_count >= 4 { self.tuning.batch.min(self.open.saturating_mul(2).max(1)) }
                   else { 1 };
        // (2) JEDEN syscall: wyślij wszystkie zakolejkowane SQE i czekaj na `wait` CQE.
        let result = self.ring.submitter().submit_with_args(wait, &SubmitArgs::new().timespec(&timeout));
        // ... obsługa ETIME/EINTR/EAGAIN/EBUSY jako "nic się nie stało" ...
        // (3) Zdejmij WSZYSTKIE ukończenia do lokalnego Vec (żeby nie trzymać pożyczki na ring).
        self.completions.clear();
        self.completions.extend(self.ring.completion().map(|c| (c.user_data(), c.result(), c.flags())));
        last_count = self.completions.len();
        // (4) Weź mutex na App (SQLite + Auth) RAZ na całą paczkę.
        let mut app = shared.lock().unwrap();
        // (5) Najpierw połączenia z odłożonym (pipelined) wejściem...
        for _ in 0..self.ready.len().min(128) { /* process(fd, &[], &mut app) */ }
        // (6) ...potem każde ukończenie: accept -> nowy Client; recv -> parsuj + serve; send -> zwolnij bufor.
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
        // (7) Oddaj jądru zużyte bufory odczytu (jeden store z Release na ogon pierścienia).
        self.publish_buffers();
        // (8) GROUP COMMIT: jeden COMMIT dla wszystkich zapisów z tej paczki.
        let committed = app.db.commit();
        // (9) Dopiero teraz odpowiedzi idą do ringu (albo zamieniają się w 500, jeśli COMMIT padł).
        self.flush(committed);
        // (10) Checkpoint WAL poza ścieżką krytyczną (tylko gdy >= 1000 ramek).
        app.db.checkpoint();
        drop(app);
        // (11) Wznów accept, jeśli zwolniło się miejsce; co 10 s zamknij połączenia zablokowane > 120 s.
        if !self.accepting && self.slots - self.open >= self.reserve * 2 { self.accept(); }
        // ...
    }
}
```

Zwróć uwagę na trzy rzeczy, których nie ma w typowej pętli:

* **Odpowiedzi nie są wysyłane w `on_recv`.** `process()` zapisuje odpowiedź do `clients[fd].output` i rejestruje ją w `self.pending` (`Pending { fd, generation, start, count, interim }`). Wysyłka następuje w `flush()` **po COMMIT**. To jest „każda odpowiedź czeka na swój commit” z zasady 6 — zaimplementowane bez żadnego kanału, oneshot ani futures.
* **Bufor „w locie” jest osobny.** `flush()` robi `c.flight = std::mem::take(&mut c.output)`. Dopóki jądro nie zgłosi CQE dla `send`, `flight` nie może się ruszyć ani zwolnić (SQE trzyma surowy wskaźnik). Nowe odpowiedzi w międzyczasie trafiają do świeżego `output`. Po `on_send` bufor wraca do puli (`retire`: max 256 buforów ≤ 16 KB na ring).
* **Backpressure bez async.** Gdy `output.len >= OUTPUT_HIGH` (64 KB), `pause(fd)` anuluje multishot recv (`AsyncCancel`) — klient, który nie czyta odpowiedzi, przestaje być czytany. `on_send` wznawia odczyt poniżej połowy progu.

### 1.3 Struktura połączenia: 64 bajty, dokładnie jedna linia cache

```rust
/// A compact owning buffer. Its allocation never moves while a send is in flight.
/// Keeping lengths as u32 makes a complete connection fit one 64-byte cache line.
#[repr(C)]
#[derive(Default)]
struct Buffer { ptr: *mut u8, len: u32, cap: u32 }        // 16 B (Vec<u8> miałby 24 B)

#[repr(C)]
#[derive(Default)]
struct Client {
    input: Buffer,    // częściowe żądanie (zwykle pusty: cap == 0, brak alokacji)
    output: Buffer,   // odpowiedzi czekające na commit
    flight: Buffer,   // odpowiedź w trakcie send
    sent: u32,
    generation: u32,
    touched: u32,     // sekundy od startu, do sweepu 120 s
    state: u32,       // bitflagi LIVE|RECEIVING|SENDING|CLOSING|SHUT|PAUSED|DIRTY|CONTINUED|READY + indeks do pending
}
const _: () = assert!(std::mem::size_of::<Client>() == 64);
```

`Vec<Client>` rośnie w krokach po 1024 (`resize_with` w `on_accept`). 64 000 połączeń = **4 MB** stanu aplikacji. Porównaj: C++ ma identyczną ideę (`struct Conn` 64 B w `mmap`-owanej tablicy indeksowanej slotem, `conn.hpp`), Zig trzyma `Connection` w rozszerzeniu gniazda uSockets (`us_socket_ext`).

### 1.4 Dlaczego Axum zużywał 1.1 GB przy 43k, a `io_uring` < 100 MB przy 64k

Kod `rust-axum-tbsvttr/src/main.rs` jest krótki i idiomatyczny — i właśnie to jest problem. Prześledźmy jedno połączenie keep-alive i jedno żądanie:

```rust
// rust-axum-tbsvttr/src/main.rs
async fn handle(State(queue): State<mpsc::Sender<Job>>, request: Request) -> Response {
    let (parts, body) = request.into_parts();
    let data = match to_bytes(body, 16384).await { ... };     // Bytes (alokacja, gdy body > 0)
    let (done, result) = oneshot::channel();                   // Arc<Inner> na stercie
    let job = Job {
        method: parts.method.to_string(),                      // String #1
        path: parts.uri.path().to_owned(),                     // String #2
        auth: parts.headers.get(header::AUTHORIZATION)...to_owned(), // String #3 (~300 B JWT)
        body: data.to_vec(),                                   // Vec #4 (kopia body)
        done,
    };
    if queue.send(job).await.is_err() { ... }                  // Job przechodzi przez mpsc
    http_response(result.await.unwrap_or_else(|_| failure(500, "internal server error")))
}
```

a po stronie aktora DB:

```rust
fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Post> {
    Ok(Post { id: row.get(0)?, body: row.get(1)?,            // String per kolumna tekstowa
              created_at: row.get(2)?, author: row.get(3)?, like_count: row.get(4)? })
}
// feed: 20 x Post = 60 Stringów + Vec<Post>, potem:
fn reply(status: u16, value: impl Serialize) -> Reply {
    (status, serde_json::to_vec(&value).expect("serializable response"))   // kolejny Vec
}
```

**Per żądanie** to ~70–80 alokacji na stercie i kilka kopii tych samych bajtów (SQLite → `String` → `serde_json` → `Vec<u8>` → `Body` → bufor zapisu hyper). Przy 40k req/s to miliony alokacji na sekundę — CPU, ale nie 1.1 GB. Pamięć bierze się z **per połączenie**:

| Składnik per połączenie keep-alive w Axum/hyper/Tokio | Szacunek |
|---|---|
| Future zadania `hyper::server::conn::http1::Connection` (maszyna stanów serwera HTTP/1 + Router + Service), zaalokowana przez `tokio::spawn` | 1–3 KB |
| Bufor odczytu hyper (`read_buf`; startuje od 8 KB i rośnie strategią adaptacyjną, zachowywany na czas keep-alive) | 8 KB+ |
| Bufor zapisu hyper (`write_buf`, nagłówki + body, zachowywany) | 8 KB |
| `TcpStream` + rejestracja w `mio`/epoll, `ScheduledIo`, `Waker`-y | ~0.3 KB |
| `ConnectionInfo { Arc<ConnectionLease> }` z `into_make_service_with_connect_info` | 0.1 KB |
| Fragmentacja alokatora systemowego (glibc malloc trzyma areny per wątek, nie zwraca pamięci) | ×1.3–1.5 |

To daje **~20–25 KB na połączenie**, a 43 000 × 25 KB ≈ **1.05 GB**. Autor sam to zmierzył: „Peak process RSS was 978.9 MiB” przy 70 000 użytkownikach na ARM64 i dodał bezpiecznik:

```rust
static KEEPALIVE_LIMIT: AtomicUsize = AtomicUsize::new(40000);
fn http_response((status, data): Reply) -> Response {
    let mut builder = Response::builder();
    if CONNECTIONS.load(Ordering::Relaxed) >= KEEPALIVE_LIMIT.load(Ordering::Relaxed) {
        builder = builder.header(header::CONNECTION, "close");   // <- "powyżej 40k zaczął zamykać połączenia"
    }
    ...
}
```

To jest dokładnie zachowanie, które widziałeś w benchmarku: powyżej ~40k serwer sam odcina keep-alive, bo inaczej skończyłby się RAM.

Dla porównania `io_uring`:

| Składnik | Zwycięski Rust |
|---|---|
| Stan połączenia | 64 B w `Vec<Client>` |
| Bufor odczytu | **0 B gdy bezczynny** — 1024 współdzielonych buforów 2 KB na ring (2 MB/ring), jądro przypisuje je tylko na czas dostarczenia danych |
| Bufor zapisu | 0 B gdy bezczynny; pula max 256 × ≤16 KB na ring (≤ 4 MB/ring), zwracana po CQE send |
| Deskryptor | slot w tablicy ringu (kilkadziesiąt bajtów w jądrze), bez `struct file` w tablicy FD procesu |
| Zadanie / future / waker | brak — stan to bitflagi w `Client.state` |

Razem: 64k × 64 B (4 MB) + 8 ringów × (2 MB + 4 MB + CQ/SQ ~0.3 MB) ≈ **55 MB** górnej granicy dla części aplikacyjnej, do tego SQLite (`cache_size=500` stron, mmap 1 GiB — ale to page cache systemu, nie anonimowa pamięć). Z `IO_URING.md`: „Mixed RSS is 40.09 → 41.06 MiB”, a przy 365 500 użytkownikach „median anonymous memory 31.94 MiB” (reszta to pamięć jądra na gniazda).

**Wniosek ogólny (nie tylko dla io_uring):** pamięć serwera z dużą liczbą keep-alive to iloczyn `liczba_połączeń × stan_bezczynnego_połączenia`. Każdy bajt trzymany *per bezczynne połączenie* liczy się 64 000 razy. Framework, który trzyma 8 KB bufora „bo może przyjdzie żądanie”, przegrywa z modelem „bufor przypisz dopiero, gdy są dane” — i to jest właśnie to, co dają provided buffers w io_uring (albo, w świecie epoll, wspólny bufor `scratch` jak w `net.rs`: `let mut scratch = vec![0u8; 65536];` jeden na całą pętlę).

### 1.5 Wątki vs ringi: dlaczego 8 workerów na 1 vCPU ma sens

```rust
// src/uring.rs, run()
let slots = limits.rlim_max.min(TARGET_SLOTS as libc::rlim_t) as usize;   // 65535 na boxie organizatora
let workers = TARGET_SLOTS.div_ceil(slots).min(MAX_WORKERS);              // 524280 / 65535 = 8
```

8 wątków nie powstało dla równoległości (na 1 vCPU nic by to nie dało). Tablica fixed files w ringu nie może być większa niż `RLIMIT_NOFILE`, więc 8 ringów × 65 535 = pojemność na 524 280 połączeń. Każdy wątek ma własny ring, ale **wszystkie dzielą jeden `Arc<Mutex<App>>`** trzymany przez cały czas obsługi paczki — SQLite skompilowane z `SQLITE_THREADSAFE=0` nigdy nie jest wołane równolegle. Przy limicie 1 048 576 autor tworzy 1 ring z 524 280 slotami i mierzy, że jest to nieco lepsze (mniej koordynacji). C++ (hendy643) rozwiązał to inaczej: 5 ringów obsługiwanych przez *jeden* wątek, zapełnianych po kolei.

---

## 2. Wzorzec Group Commit (batching transakcji SQLite)

### 2.1 Wersja `io_uring`: transakcja odłożona, commit per paczka CQE (`src/db.rs`)

```rust
pub struct Db {
    feed: Stmt, feed_ids: Stmt, feed_likes: Stmt, feed_rows: Stmt, feed_scratch: Vec<u8>,
    post: Stmt, health: Stmt, insert: Stmt, created: Stmt, like: Stmt, exists: Stmt,
    begin_stmt: Stmt, commit_stmt: Stmt, rollback_stmt: Stmt,     // BEGIN/COMMIT też są prepared!
    raw: *mut Connection,
    wal_frames: Box<Cell<i32>>,
    pub transaction: bool,
    pub group: bool,
}

fn begin(&mut self) -> bool {
    if !self.group || self.transaction { return true; }        // już w transakcji -> nic
    if !Self::transaction_step(&mut self.begin_stmt) { return false; }
    self.transaction = true;
    true
}
pub fn commit(&mut self) -> bool {
    if !self.transaction { return true; }                      // paczka bez żadnego zapytania
    let ok = Self::transaction_step(&mut self.commit_stmt);
    if !ok { Self::transaction_step(&mut self.rollback_stmt); }
    self.transaction = false;
    ok
}
```

Każda metoda — `read()`, `create()`, `like()` — zaczyna się od `if !self.begin() { return error(...500...) }`. **Także odczyty.** Po co? Cytat z README: „Live reads share a deferred SQLite transaction through each serialized completion batch. Writes upgrade it as needed, avoiding repeated pager setup while keeping every query live.” Zwykłe `BEGIN` (deferred) nie bierze blokady zapisu; pierwszy `INSERT` w paczce podnosi ją do write. Zysk zmierzony w `IO_URING.md`: feed +23 %, single post +28 %, bo SQLite nie robi `fstat`/pager setup per zapytanie („3.001 versus 1.000 file-stat calls per read-only feed request”).

Checkpoint jest poza ścieżką odpowiedzi i sterowany licznikiem ramek z `sqlite3_wal_hook`:

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

`PRAGMA wal_autocheckpoint=0` wyłącza automatyczny checkpoint w środku `COMMIT`; pętla woła `checkpoint()` *po* `flush()`, więc klienci dostają odpowiedzi, zanim SQLite zacznie przepisywać WAL do pliku głównego.

### 2.2 Wybudzanie klientów bez blokowania pętli: `Pending` + `flush`

Nie ma tu kanałów. W momencie obsługi żądania `process()` zapisuje odpowiedź do bufora połączenia i zapamiętuje *gdzie*:

```rust
struct Pending { fd: usize, generation: u32, start: u32, count: u32, interim: bool }

fn dirty(&mut self, fd: usize) -> usize {
    let c = &mut self.clients[fd];
    if c.state & DIRTY != 0 { return (c.state >> INDEX_SHIFT) as usize; }   // już w pending
    let index = self.pending.len();
    self.pending.push(Pending { fd, generation: c.generation, start: c.output.len, count: 0, interim: false });
    c.state |= DIRTY | ((index as u32) << INDEX_SHIFT);   // indeks do pending upchnięty w górnych bitach state
    index
}
```

Po `commit()` pętla woła `flush(committed)`:

```rust
fn flush(&mut self, committed: bool) {
    if !committed {
        // COMMIT padł: cofnij każdy output do `start` i wpisz tyle odpowiedzi 500, ile było żądań
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
        if c.state & LIVE == 0 || c.state & SENDING != 0 { continue; }   // poprzedni send jeszcze w locie
        if c.output.len != 0 {
            c.flight = std::mem::take(&mut c.output);                     // przenieś własność bufora
            c.sent = 0;
            self.send(fd);                                               // jedno SQE send
        } else if c.state & CLOSING != 0 { self.close(fd); }
    }
    self.pending.clear();
}
```

Dwie własności tego rozwiązania są trudne do uzyskania w modelu async:

1. **Pipelining HTTP jest zachowany w razie awarii.** Gdy klient wysłał 3 żądania w jednym pakiecie i COMMIT padł, odpowiedzi 1–3 są zamienione na 3 × 500 *w tej samej kolejności*, bo `Pending.count` pamięta, ile ramek było w tym zakresie bufora.
2. **Odczyt, który „widział” niezatwierdzony zapis, też czeka.** Ponieważ odczyty dzielą transakcję, feed obsłużony po `INSERT` w tej samej paczce zawiera nowy post. Gdyby odpowiedź na feed wyszła, a COMMIT padł, klient zobaczyłby dane, które nigdy nie istniały. `flush` po `commit` załatwia to automatycznie: *nic* nie wychodzi przed COMMIT.

### 2.3 Wersja Axum #1 (tbsvttr): aktor na jednym wątku Tokio + `yield_now` jako timer

```rust
// rust-axum-tbsvttr/src/main.rs
async fn work(mut self, mut queue: mpsc::Receiver<Job>) {
    let mut replies = Vec::with_capacity(256);
    while let Some(first) = queue.recv().await {
        tokio::task::yield_now().await; // Batch ready requests without a timer.
        let mut next = Some(first);
        while let Some(job) = next {
            let result = self.handle(&job).unwrap_or_else(|_| failure(500, "internal server error"));
            if self.transaction && self.db.is_autocommit() { self.failed = true; }   // SQLite sam zrobił rollback
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

Sprytny element: `tokio::task::yield_now().await` po pierwszym zadaniu. Runtime jest `current_thread`, więc `yield_now` oddaje głos *wszystkim* zadaniom hyper, które właśnie dostały dane z epoll; one wrzucają swoje `Job`-y do kanału, a aktor zbiera je `try_recv()` — bez timera, bez dodatkowej latencji, gdy nie ma ruchu. `begin()` robi `BEGIN IMMEDIATE` dopiero przy pierwszym zapisie. Odpowiedzi wracają przez `oneshot::Sender<Reply>` — każdy handler hyper czeka w `result.await`.

Koszt w porównaniu z `io_uring`: per żądanie `Job` (3 Stringi + Vec), `oneshot` (alokacja `Arc`), przejście przez `mpsc` (atomics + wakeup), a odpowiedź jest kopiowana jeszcze raz do `Body`. Ale **model jest ten sam**: jeden właściciel połączenia SQLite, paczka żądań gotowych „teraz”, jeden COMMIT, dopiero potem wybudzenie klientów.

### 2.4 Wersja Axum #2 (SvetlinZarev): osobny wątek writer, odczyty równolegle

```rust
// rust-axum-SvetlinZarev/src/db.rs
pub fn writer_loop(path: String, mut rx: mpsc::Receiver<Write>) {
    let conn = open_conn(&path, false);
    let mut stmts = WriteStmts::new(&conn);                 // prepared raz, żyją cały czas
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

`commit_batch` robi `BEGIN` → wszystkie `INSERT` → `COMMIT`; przy błędzie `ROLLBACK` i `retry_individually` (każdy zapis osobno, żeby jedna zła operacja nie zatopiła sąsiadów). Odczyty idą przez `thread_local! READ_CONN` — osobne połączenie read-only per wątek Tokio (`with_read(|conn| ...)`). To jest klasyczny wzorzec „single writer, N readers” dla WAL. Jego słabość przy 1 vCPU: writer to **dodatkowy wątek**, więc każdy zapis to dwa przełączenia kontekstu (Tokio → writer → Tokio) i brak współdzielenia transakcji z odczytami.

### 2.5 Jak to zrobił C++ i Zig

* C++ (`server.cpp`): `commit_group()` wołane po obsłudze paczki CQE **lub** gdy `deferred_count_ == kMaxDeferred`; przed tym `io_uring_submit_and_wait_timeout(..., busy ? 128 : 1, busy ? 6 ms : idle)`. Autor zmierzył CPU per żądanie w funkcji wielkości paczki: „25 us with no batching, 21 us at 1.5 ms, 18 us at 3 ms, 16.7 us at 6 ms, 15.6 us at 12 ms. 6 ms is where it flattens” — i zapłacił za to p99 ≈ 7 ms zamiast < 1 ms. Rust wybrał 32 CQE / 250 µs — mniejsze paczki, niższa latencja.
* Zig (`main.zig`): `deliver()` dokłada odpowiedź do globalnej `pending: ArrayList(Pending)`; `afterLoop` (callback uSockets po każdej iteracji pętli) woła `flush()`, która robi COMMIT i dopiero potem `us_socket_write`. `if (pending.items.len >= 256) flush();` — identyczny limit jak w Axum #1.

**Wspólny mianownik wszystkich czwórki:** granicą paczki jest *iteracja pętli zdarzeń*, nie timer. Timer dodaje latencję zawsze; iteracja pętli dodaje ją tylko wtedy, gdy faktycznie jest co grupować.

---

## 3. Zero-allocation, parsowanie HTTP, krypto i JSON prosto z SQLite

Autor zwycięskiego kodu ma test (`tests/support/allocations.rs`, uruchamiany `cargo test --release -- --ignored`), który liczy wywołania alokatora podczas 100 rozgrzanych żądań na każdym z 5 endpointów i **oczekuje zera**. Zobaczmy, jak to osiąga.

### 3.1 Bufory: wszystko jest `extend` do istniejącego `Vec<u8>`/`Buffer`

Hot path operuje na trzech reużywanych buforach:

* `Worker.body: Vec<u8>` (16 KB) — ciało odpowiedzi budowane przez `App::serve(&req, &mut self.body)`,
* `Client.output: Buffer` — pobierany z `Worker.pool` (`self.pool.pop().unwrap_or_default()`), zwracany po send,
* `Db.feed_scratch: Vec<u8>` — bufor na wiersze feedu przed przestawieniem w kolejności.

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
    out.extend(itoa::Buffer::new().format(body.len()).as_bytes());   // itoa: liczba -> bajty na stosie
    out.extend(if close { b"\r\nConnection: close\r\n\r\n" } else { b"\r\n\r\n" });
    out.extend(body);
}
```

Nie ma `format!`, nie ma `String`, nie ma `HeaderMap`. Status to `u16`, a `match` na stałych bajtowych kompiluje się do tablicy wskaźników.

### 3.2 Parsowanie HTTP: `httparse` + pożyczki, zero kopiowania

```rust
// src/main.rs
pub struct Frame<'a> {
    method: &'a str, path: &'a str,
    authorization: Option<&'a str>,
    body: Cow<'a, [u8]>,          // Borrowed dla Content-Length, Owned tylko dla chunked (rzadkie)
    pub consumed: usize, pub close: bool,
}
pub fn frame(input: &[u8]) -> Result<Parsed<'_>, ()> {
    let mut headers = [httparse::EMPTY_HEADER; 64];      // 64 x 32 B na STOSIE
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

`Frame<'a>` żyje tyle, co bufor odczytu z jądra (`bytes` w `on_recv` to `from_raw_parts` na provided buffer). Nic nie jest kopiowane do `String`. Dla porównania Axum: hyper parsuje do `http::Request` z `HeaderMap` (hash-mapa z alokowanymi `HeaderValue`), a potem autor i tak kopiuje do `Job { method: String, path: String, auth: String }`.

C++ poszedł o krok dalej (SSE2 skan nagłówków 16 bajtów naraz: „A `GET` parses in about 35 ns vs 70-80 for `memmem`/`memchr`”), ale w profilu Rusta parsowanie HTTP nie jest widoczne — więc `httparse` wystarcza.

### 3.3 Krypto: HMAC z prekomputowanym kluczem, podpis na stosie

```rust
// src/main.rs
struct Auth { mac: Hmac<Sha256>, header: Vec<u8>, payload: Vec<u8> }   // bufory reużywane

fn user(&mut self, authorization: Option<&str>) -> Result<(i64, Cow<'_, str>), &'static str> {
    let token = authorization.and_then(|a| a.strip_prefix("Bearer ")).ok_or("missing bearer token")?;
    let mut pieces = token.split('.');
    let (h, p, s) = (pieces.next()?, pieces.next()?, pieces.next()?);
    let mut sig = [0u8; 33];                                        // 32 B podpisu + zapas, na stosie
    let n = URL_SAFE_NO_PAD.decode_slice(s, &mut sig).map_err(|_| bad)?;
    let mut mac = self.mac.clone();                                 // klon stanu po ipad: ~100 B memcpy, 0 alokacji
    mac.update(&token.as_bytes()[..h.len() + 1 + p.len()]);        // podpisujemy surowe bajty "header.payload"
    mac.verify_slice(&sig[..n]).map_err(|_| bad)?;                  // stałoczasowe porównanie
    self.header.clear();
    URL_SAFE_NO_PAD.decode_vec(h, &mut self.header).map_err(|_| bad)?;   // decode DO istniejącego Vec
    let header: Header = serde_json::from_slice(&self.header).map_err(|_| bad)?;   // Cow<str> borrowed
    if header.alg != "HS256" { return Err(bad); }
    self.payload.clear();
    URL_SAFE_NO_PAD.decode_vec(p, &mut self.payload).map_err(|_| bad)?;
    let claims: Claims = serde_json::from_slice(&self.payload).map_err(|_| bad)?;
    ...
}
```

Kolejność jest celowa: **najpierw podpis, potem JSON**. Token z błędnym podpisem nigdy nie trafia do parsera JSON (odporność na nadużycia i mniej pracy). `Hmac::new_from_slice` wołane jest raz w `Auth::new`; `clone()` kopiuje przetworzony blok klucza (`ipad`/`opad`). C++ robi dokładnie to samo ręcznie: `SHA256_Init(&inner_); SHA256_Update(&inner_, pad, 64)` w konstruktorze `JwtVerifier`, a `verify` kopiuje `SHA256_CTX` — „a request costs two short hash continuations”.

Claims są czytane jako pożyczki, bez `serde_json::Value`:

```rust
#[derive(Deserialize)]
struct Claims<'a> {
    #[serde(borrow)] sub: Option<&'a serde_json::value::RawValue>,   // surowy wycinek JSON, 0 alokacji
    #[serde(borrow)] username: Option<&'a serde_json::value::RawValue>,
    exp: Option<f64>,
    nbf: Option<f64>,
}
```

Porównaj Axum #1: `let parts: Vec<_> = token.split('.').collect(); let mut decoded = Vec::with_capacity(3); ... decoded.push(URL_SAFE_NO_PAD.decode(part)?)` + `let claims: Value = serde_json::from_slice(&decoded[1])` + `Hmac::new_from_slice(&self.secret)` *per żądanie* — ok. 10 alokacji i ponowne przetworzenie klucza przy każdym tokenie.

### 3.4 JSON wejściowe: wizytor, który czyta tylko `body`

Zamiast `serde_json::Value` (drzewo, `Map<String, Value>` = alokacje per klucz) autor napisał `DeserializeSeed`, który przechodzi cały dokument (pełna walidacja, bo spec wymaga 400 dla złego JSON), ale zapamiętuje jeden string:

```rust
#[derive(Clone, Copy)]
enum BodySeed { Root, String, Ignore }
impl<'de> serde::de::Visitor<'de> for BodySeed {
    type Value = Option<Cow<'de, str>>;
    fn visit_borrowed_str<E>(self, s: &'de str) -> Result<Self::Value, E> {
        Ok(matches!(self, Self::String).then_some(Cow::Borrowed(s)))   // bez escape'ów: pożyczka z bufora
    }
    fn visit_str<E>(self, s: &str) -> Result<Self::Value, E> {          // z escape'ami: serde zdekodował do tymczasowego
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
    // visit_seq / visit_i64 / ... zwracają None — ale ich wywołanie oznacza, że serde zwalidował token
}
```

### 3.5 JSON wyjściowe „prosto z SQLite”

Nie ma tu `json_object()` w SQL (C++ i Rust uznały, że koszt SQLite'owego budowania JSON jest większy niż własnego writera — profil pokazał, że to interpreter SQLite jest wąskim gardłem, nie escapowanie). Zamiast tego: **surowe bajty kolumny → escapowanie → bufor wyjściowy**, bez `String` po drodze:

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
    out.extend_from_slice(b",\"body\":");        crate::json_string(stmt.text(1), out);   // &[u8] z SQLite -> escape -> out
    out.extend_from_slice(b",\"created_at\":");  crate::json_string(stmt.text(2), out);
    out.extend_from_slice(b",\"author\":");      crate::json_string(stmt.text(3), out);
    out.extend_from_slice(b",\"like_count\":");  crate::number(likes, out);
    out.push(b'}');
}
```

a `json_string` ma szybką ścieżkę SIMD dla czystego ASCII:

```rust
// src/main.rs — 16 bajtów naraz: czy jest tu `"`, `\` albo bajt < 0x20?
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
        if i + 16 <= b.len() && plain16(&b[i..]) { i += 16; continue; }   // 16 B bez kopiowania, bez gałęzi per bajt
        let c = b[i];
        if c < 32 || c == b'"' || c == b'\\' {
            out.extend_from_slice(&b[start..i]);        // skopiuj czysty fragment hurtowo
            match c { b'"' => out.extend_from_slice(b"\\\""), b'\\' => ..., b'\n' => ..., _ => /* \u00XX */ }
            start = i + 1;
        }
        i += 1;
    }
    out.extend_from_slice(&b[start..]);
    out.push(b'"');
}
```

Dart (`dart-rawsocket-C-Hatton`) ma wierną kopię tej idei: `CAST(p.body AS BLOB)` w SELECT, a potem `_Out.str(Uint8List)` z tym samym escapowaniem bajt po bajcie — „It took `GET /feed` from 13.5k to 23k req/s on one core (+70%)”.

### 3.6 Feed jako trzy skany zakresowe (`range_feed`)

Zapytanie referencyjne (`SELECT ... (SELECT count(*) FROM likes l WHERE l.post_id=p.id) ... LIMIT 20`) to 20 podzapytań `count(*)` przez indeks. Autor zauważył, że 20 najnowszych postów ma zwykle *prawie ciągłe* ID:

```rust
// src/db.rs
fn range_feed(&mut self, out: &mut Vec<u8>) -> Option<u16> {
    let mut ids = [0i64; 20];                                   // na stosie
    // (1) SELECT id FROM posts ORDER BY created_at DESC,id DESC LIMIT 20
    ...
    if maximum.checked_sub(minimum)? >= 256 { return None; }   // ID rozrzucone -> zwykłe zapytanie
    let mut slots = [-1i8; 256];                                // mapa id -> pozycja w feedzie, na stosie
    // (2) SELECT post_id FROM likes WHERE post_id BETWEEN ?1 AND ?2     -> jeden skan indeksu, zliczanie do likes[20]
    // (3) SELECT p.id,p.body,p.created_at,u.username FROM posts p JOIN users u ... WHERE p.id BETWEEN ?1 AND ?2
    //     -> wiersze do feed_scratch, a `segments[slot]` pamięta (start,end) każdego posta
    // (4) złóż odpowiedź w oryginalnej kolejności (created_at DESC, id DESC) kopiując segmenty
    ...
}
```

Zasada 5 (brak cache) jest zachowana — każde żądanie odkrywa ID na nowo. To nie jest „trik Rusta”, to trik „myśl o planie zapytania”: 3 skany sekwencyjne zamiast 1 + 20 losowych lookupów. C++ ma identyczny „Feed as three range scans”.

---

## 4. Analiza `unsafe` i `Cargo.toml`

### 4.1 `Cargo.toml` zwycięzcy

```toml
[package]
name = "twelve-rust-poll"
edition = "2024"
build = "build.rs"
[features]
default = ["sqlite-pgo"]
sqlite-pgo = []
[dependencies]
io-uring = "=0.7.15"      # cienki wrapper na syscalle io_uring, bez executora
libc = "=0.2.183"
httparse = "=1.10.1"      # parser HTTP/1 bez alokacji (nagłówki na stosie)
memchr = "=2.8.0"         # SIMD memmem dla chunked encoding
serde = { version = "=1.0.228", features = ["derive"] }
serde_json = { version = "=1.0.149", features = ["raw_value"] }   # RawValue = pożyczanie fragmentów JSON
itoa = "=1.0.18"          # int -> bajty bez fmt
base64 = "=0.22.1"
sha2 = "=0.10.9"
hmac = "=0.12.1"
[build-dependencies]
cc = "=1.2.56"            # kompiluje vendor/sqlite3.c
[profile.release]
opt-level = 3
lto = "fat"               # jeden moduł LLVM: inlining przez granice crate'ów (serde, httparse, io-uring)
codegen-units = 1         # bez podziału na jednostki: lepsza optymalizacja, dłuższa kompilacja
panic = "abort"           # bez tablic unwind, mniejszy kod, brak kosztów landing pads
strip = true
```

Do tego `build.sh`: `export RUSTFLAGS="-C target-cpu=native"` (SSE4/AVX2 dla całego binarium) i `build.rs` kompilujący SQLite z:

```rust
.define("SQLITE_THREADSAFE", "0")          // zero mutexów w SQLite — serializacja jest po stronie Rusta (Mutex<App>)
.define("SQLITE_DEFAULT_MEMSTATUS", "0")   // bez globalnego licznika pamięci (atomics per malloc)
.define("SQLITE_DQS", "0")
.define("SQLITE_OMIT_LOAD_EXTENSION", None)
.define("SQLITE_OMIT_DEPRECATED", None)
.define("SQLITE_OMIT_SHARED_CACHE", None)
.define("SQLITE_OMIT_PROGRESS_CALLBACK", None)
.define("SQLITE_LIKE_DOESNT_MATCH_BLOBS", None)
.define("SQLITE_USE_ALLOCA", None)
```

plus PGO SQLite: `build.rs` buduje `bench/train_sqlite.c` z `-fprofile-generate`, uruchamia go na syntetycznej bazie i rekompiluje `sqlite3.c` z `-fprofile-use`. C++ mierzył efekt: „feed 11.6 us vs 16.3 for Ubuntu's 3.45.1, post lookup 3.7 vs 4.5” (−30 %). To jest największy pojedynczy zysk, jaki można uzyskać *bez dotykania własnego kodu* — bo 50–60 % profilu to interpreter SQLite.

Dla porównania Axum #1 ma identyczny profil release (`lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = true`) i także własne SQLite 3.53.4 linkowane statycznie — czyli *sam profil kompilatora nie wyjaśnia różnicy 43k vs 64k*. Axum #2 ma `lto = "thin"` i `tikv-jemallocator` (jemalloc redukuje fragmentację i zwraca pamięć — rozsądny wybór, gdy alokujesz dużo per żądanie).

### 4.2 Gdzie i po co jest `unsafe` — i co dałoby się zastąpić

W `uring.rs`, `db.rs`, `main.rs`, `net.rs` jest ~45 bloków `unsafe`. Pogrupowane:

| # | Kategoria | Przykład | Zysk wydajnościowy | Bezpieczny zamiennik |
|---|---|---|---|---|
| 1 | **FFI do SQLite** (`db.rs`: `extern "C"`, `sqlite3_step`, `sqlite3_column_text`, `sqlite3_bind_text` z `SQLITE_STATIC`) | `Stmt::text()` zwraca `&[u8]` pożyczony od SQLite | **Kluczowy.** Zero kopii kolumn; `SQLITE_STATIC` przy bind oznacza, że `body` nie jest kopiowane do SQLite. `rusqlite` dla `&str` używa `SQLITE_TRANSIENT`? Nie — rusqlite także binduje `&str` jako `SQLITE_STATIC` i zwraca `ValueRef<'_>` pożyczone; różnica wobec rusqlite to głównie brak `Result` per kolumna, brak cache statementów (hash lookup) i `SQLITE_THREADSAFE=0` | `rusqlite` z `prepare_cached` i `ValueRef::as_bytes()` da ~95 % tej wydajności. Autor wybrał własne bindingi, by kontrolować kompilację SQLite i mieć 0 zależności „grubych” |
| 2 | **Składanie SQE** (`uring.rs::queue`: `ring.submission().push(&entry)`) | — | Wymuszone przez crate `io-uring`: `push` jest `unsafe`, bo SQE zawiera surowe wskaźniki, których życiem zarządza użytkownik | Brak (to kontrakt biblioteki). Alternatywa `tokio-uring`/`monoio` daje bezpieczne API kosztem executora i własności buforów (`Vec<u8>` przenoszony do operacji — alokacje) |
| 3 | **Własny `Buffer` z `alloc/realloc/dealloc`** (`uring.rs`) | `#[repr(C)] struct Buffer { ptr, len: u32, cap: u32 }` | Umiarkowany. 16 B zamiast 24 B dla `Vec<u8>` pozwala zmieścić `Client` w 64 B (jedna linia cache; 64 000 × 64 B = 4 MB). Stabilny adres podczas `send` i tak zapewnia zakaz `reserve` na `flight` | `Vec<u8>` + `Client` 88 B. Przy 64k połączeń to +1.5 MB i część klientów na dwu liniach cache. Autor nie mierzył osobno; w profilu przy 365k użytkownikach „kernel established-connection lookup” dominuje LLC-misses, nie struktura Client. **Werdykt: zamienne bez mierzalnej straty** poniżej ~100k połączeń |
| 4 | **`mmap` dla provided buffers** (`Mapping`) | `libc::mmap(MAP_PRIVATE \| MAP_ANONYMOUS)` | Potrzebne wyrównanie do strony dla `register_buf_ring` | `std::alloc::alloc(Layout::from_size_align(n, 4096))` — też `unsafe`. Bezpieczne crate'y (`memmap2::MmapMut::map_anon`) usuwają `unsafe` z Twojego kodu bez kosztu |
| 5 | **Publikacja buforów** (`recycle`, `publish_buffers`: pisanie `BufRingEntry` i `AtomicU16::store(tail, Release)`) | — | Kluczowe dla modelu „0 B per bezczynne połączenie” | Brak bezpiecznego odpowiednika w `io-uring 0.7`; to jest protokół współdzielonej pamięci z jądrem |
| 6 | **`from_raw_parts` na bufor odczytu** (`on_recv`) | `slice::from_raw_parts(recv_memory.ptr.add(bid * BUFSIZE), result)` | Kluczowe: zero kopii z bufora jądra do parsera | Można zrobić `recv_memory` jako `&mut [u8]` z `Mapping` raz i indeksować `&buf[bid*BUFSIZE..][..result]` — bezpieczny slice bez różnicy w kodzie maszynowym |
| 7 | **SIMD `plain16`** (`main.rs`) | `_mm_loadu_si128` | Mały. Profil: JSON escaping ≈ 3.9–4.2 % feedu. Autor testował AVX2 intrinsics i ręczny assembler — „neither scanner is shipped” (regresja 1–3 % na krótkich stringach) | Pętla skalarna `b[..16].iter().all(|&c| c >= 32 && c != b'"' && c != b'\\')` — LLVM często autowektoryzuje; strata < 1 % całości. Albo `std::simd` (nightly) |
| 8 | **`unsafe impl Send for App`** | surowe wskaźniki `*mut Connection` w `Db` | Zerowy wpływ na wydajność; to tylko uspokojenie kompilatora, bo `App` jest przenoszony między wątkami pod `Mutex` | Newtype `struct Conn(*mut Connection); unsafe impl Send for Conn {}` z komentarzem — nadal `unsafe`, ale ograniczony do 1 linii. Albo `rusqlite::Connection`, które jest `Send` |
| 9 | **`libc::getrlimit/setrlimit/setsockopt/listen`** (`uring.rs::run`) | TCP_NODELAY, backlog 4096, podniesienie soft limitu | Zerowy w hot path (raz na start) | `socket2::Socket::set_nodelay`, `rlimit` crate — **zamień bez wahania** |
| 10 | **Cały `net.rs` (epoll przez `libc`)** | `epoll_wait`, `accept4`, `recv`, `send` | Ścieżka porównawcza (`--epoll`), nie produkcyjna | `mio` daje to samo bezpiecznie; różnica niemierzalna |
| 11 | **`wal_hook` callback i `Box<Cell<i32>>`** (`db.rs`) | wskaźnik do `Cell` przekazywany do C | Checkpoint poza ścieżką odpowiedzi | `rusqlite` nie eksponuje `sqlite3_wal_hook`; alternatywa `PRAGMA wal_checkpoint(PASSIVE)` co N commitów (jak w Axum #2) — bezpieczne, ~ten sam efekt |

**Podsumowanie:** `unsafe`, które naprawdę kupuje wydajność, to **1, 5, 6** (zero-copy między jądrem, parserem i SQLite) i pośrednio **2, 4** (narzucone przez io_uring). Punkty **3, 7, 8, 9, 10, 11** można zastąpić bezpiecznym Rustem albo sprawdzonymi crate'ami bez mierzalnej straty — i tak zrobiłbym w kodzie produkcyjnym. Autor zresztą sam pisze w README: „Unsafe code covers C bindings, Linux I/O, vector loads and compact owning buffers” — i udokumentował niezmienniki przy każdym bloku (to jest wzorzec do skopiowania: **każdy `unsafe` ma komentarz „dlaczego to jest poprawne”**).

### 4.3 Czego się nauczyć z `IO_URING.md` (metodologia)

Ten plik jest równie cenny jak kod:

* **Profil przed optymalizacją.** „feed flat samples put 24.36% in SQLite's interpreter, 8.37% in table lookup and 3.87% in JSON escaping … SQLite transaction setup therefore offers a larger target than a JSON-only assembly rewrite.” — i rzeczywiście: deferred read transaction dało +23 %, a ręczny AVX2 nic.
* **Balanced order (AB/BA) i mediany**, nie pojedyncze runy; raportowanie zakresów; przyznanie, że „clock variation prevents a guarantee that every run improves”.
* **Eksperymenty odrzucone są udokumentowane**: branchless, unchecked indexing (`get_unchecked`) — „Feed medians were 1.52% and 0.61% below control” → nie weszły. Lekcja: `unsafe` dla pominięcia bounds-check *nie* dał zysku, bo LLVM i tak usuwa większość sprawdzeń w pętlach o znanym zakresie.
* Bitwise `|` zamiast `||` w predykacie JSON: „release executable is byte-for-byte identical to control” — kompilator już to zrobił.

---

## 5. Praktyczna ściąga: produkcyjny Rust (80 % zysku przy 20 % wysiłku)

Nie musisz pisać własnego serwera HTTP. Pięć wzorców z tego repozytorium, które przenoszą się 1:1 do Axum/Tokio:

### 5.1 Jeden właściciel bazy + group commit per „tick”

**Typowy, wolny kod:**

```rust
// Pool połączeń, każdy handler otwiera własną transakcję => 1 fsync per zapis, SQLITE_BUSY pod obciążeniem
async fn like(State(pool): State<Pool>, Path(id): Path<i64>, user: User) -> impl IntoResponse {
    let conn = pool.get().await?;
    conn.execute("INSERT INTO likes(user_id,post_id) VALUES(?,?) ON CONFLICT DO NOTHING", params![user.id, id])?;
    StatusCode::CREATED
}
```

**W stylu 12-Dollar-Server (Axum #1 + idea `Pending`):**

```rust
enum Write { Like { user: i64, post: i64, done: oneshot::Sender<Result<bool>> }, Create { ... } }

async fn like(State(tx): State<mpsc::Sender<Write>>, Path(id): Path<i64>, user: User) -> impl IntoResponse {
    let (done, rx) = oneshot::channel();
    tx.send(Write::Like { user: user.id, post: id, done }).await.ok();
    match rx.await { Ok(Ok(true)) => StatusCode::CREATED, Ok(Ok(false)) => StatusCode::OK, _ => StatusCode::INTERNAL_SERVER_ERROR }
}

fn writer(conn: Connection, mut rx: mpsc::Receiver<Write>) {         // std::thread albo tokio::spawn na current_thread
    let mut like = conn.prepare("INSERT INTO likes ... ON CONFLICT DO NOTHING").unwrap();   // prepared RAZ
    let mut batch = Vec::with_capacity(256);
    while let Some(first) = rx.blocking_recv() {
        batch.push(first);
        while batch.len() < 256 { match rx.try_recv() { Ok(w) => batch.push(w), Err(_) => break } }   // zbierz to, co już czeka
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        let results: Vec<_> = batch.iter().map(|w| apply(&mut like, w)).collect();
        let committed = conn.execute_batch("COMMIT").is_ok();
        for (w, r) in batch.drain(..).zip(results) {
            let _ = w.done().send(if committed { r } else { Err(anyhow!("commit failed")) });   // odpowiedź DOPIERO po COMMIT
        }
    }
}
```

Reguły: `wal_autocheckpoint=0` + własny `PRAGMA wal_checkpoint(PASSIVE)` między paczkami; `BEGIN IMMEDIATE` (od razu blokada zapisu, bez eskalacji w środku); odpowiedź wysyłana *po* `COMMIT`; przy błędzie — cała paczka dostaje błąd albo retry pojedynczo (Axum #2).

### 5.2 Pożyczaj, nie kopiuj: `&str`/`&[u8]`/`Cow`/`RawValue` w strukturach żądania

**Wolno:**

```rust
#[derive(Deserialize)]
struct Claims { sub: String, username: String, exp: f64 }            // 2 alokacje String
let v: serde_json::Value = serde_json::from_slice(&body)?;           // drzewo: Map + String per klucz
let text = v["body"].as_str().unwrap_or("").to_owned();              // kolejna kopia
```

**Szybko:**

```rust
#[derive(Deserialize)]
struct Claims<'a> {
    #[serde(borrow)] sub: Cow<'a, str>,                              // pożyczka, gdy brak escape'ów
    #[serde(borrow)] username: Cow<'a, str>,
    exp: f64,
}
#[derive(Deserialize)]
struct CreatePost<'a> { #[serde(borrow)] body: Cow<'a, str> }         // tylko potrzebne pole
let req: CreatePost = serde_json::from_slice(&body_bytes)?;          // body_bytes: axum::body::Bytes
```

W Axum odbierz body jako `Bytes` (nie `Json<T>` z owned polami, nie `String`) i deserializuj z pożyczkami. Odpowiedź buduj do `Vec<u8>` i oddaj jako `Body::from(vec)` — `serde_json::to_vec` zamiast `to_string` + `.into()`.

### 5.3 Prepared statements trzymane w strukturze, kolumny czytane jako bajty

**Wolno:**

```rust
let mut stmt = conn.prepare("SELECT ...")?;                           // kompilacja SQL per żądanie
let posts: Vec<Post> = stmt.query_map([], |r| Ok(Post { body: r.get(1)?, .. }))?.collect()?;   // String per kolumna
let json = serde_json::to_vec(&Feed { posts })?;                     // druga serializacja
```

**Szybko (rusqlite, bez `unsafe`):**

```rust
struct Db { conn: Connection, feed: Statement<'static> /* przez self_cell/ouroboros */ }   // albo conn.prepare_cached(SQL) z dużą pojemnością cache
let mut rows = self.feed.query([])?;
out.extend_from_slice(b"{\"posts\":[");
while let Some(row) = rows.next()? {
    let body: &[u8] = row.get_ref(1)?.as_bytes()?;                   // ValueRef<'_>: pożyczka, 0 kopii
    out.extend_from_slice(b"{\"id\":"); write_int(row.get::<_, i64>(0)?, &mut out);
    out.extend_from_slice(b",\"body\":"); write_json_string(body, &mut out);   // Twoja funkcja escapująca (patrz 3.5)
    ...
}
out.extend_from_slice(b"]}");
```

`prepare_cached` + `set_prepared_statement_cache_capacity(N)` to 1 linia i −30 % CPU na SQLite w typowym serwisie. Czytanie `ValueRef::as_bytes()` zamiast `String` to kolejne −20 % na endpointach listujących.

### 5.4 Reużywaj bufory per task/wątek; `itoa`, `write!` do `Vec<u8>` zamiast `format!`

**Wolno:**

```rust
let header = format!("HTTP/1.1 {} OK\r\nContent-Length: {}\r\n\r\n", status, len);   // String + fmt
let body = format!("{{\"liked\":true,\"post_id\":{}}}", id);
```

**Szybko:**

```rust
thread_local! { static OUT: RefCell<Vec<u8>> = RefCell::new(Vec::with_capacity(16 * 1024)); }
OUT.with(|b| {
    let mut out = b.borrow_mut(); out.clear();
    out.extend_from_slice(b"{\"liked\":true,\"post_id\":");
    out.extend_from_slice(itoa::Buffer::new().format(id).as_bytes());
    out.push(b'}');
    // skopiuj do Bytes raz (Bytes::copy_from_slice) — albo trzymaj pulę Vec jak `Worker.pool`
});
```

W Tokio `thread_local!` działa, bo zadanie nie przełącza wątku *w trakcie* synchronicznego fragmentu. Nie trzymaj pożyczki przez `.await`.

### 5.5 Mierz i konfiguruj: SQLite pragmy, profil release, `target-cpu`, batching sterowany obciążeniem

```sql
PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;          -- 1 fsync per commit zamiast 2
PRAGMA locking_mode=EXCLUSIVE;                               -- (tylko jeden proces!) bez fcntl shm-lock per odczyt
PRAGMA mmap_size=1073741824; PRAGMA cache_size=500;          -- czytaj z page cache OS, nie dubluj go w SQLite
PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=0;       -- checkpoint rób sam, poza ścieżką odpowiedzi
```

```toml
[profile.release]
lto = "fat"; codegen-units = 1; panic = "abort"; strip = true
# + RUSTFLAGS="-C target-cpu=native" jeśli binarium biegnie na maszynie, na której było zbudowane
```

I regulator batchingu: pod obciążeniem czekaj na „kilka zdarzeń lub krótki timeout”, bezczynnie — na jedno zdarzenie. W Tokio odpowiednikiem jest `yield_now().await` po pierwszym elemencie (Axum #1) albo `tokio::time::timeout(Duration::from_micros(250), rx.recv())` w pętli writera **tylko gdy** poprzednia paczka miała ≥ 4 elementy.

### 5.6 Tabela „wolno vs szybko” w jednym miejscu

| Obszar | Typowy Rust | Styl 12-Dollar-Server | Spodziewany zysk |
|---|---|---|---|
| Transakcje | autocommit per żądanie, pool połączeń | 1 writer, `BEGIN IMMEDIATE`…`COMMIT` per paczka, odpowiedź po commit | 5–20× przepustowości zapisów |
| SQL | `conn.prepare` per żądanie | `Statement` w strukturze / `prepare_cached` | −20–30 % CPU SQLite |
| Kolumny | `row.get::<String>` | `get_ref().as_bytes()` → własny writer | −50 % alokacji na endpointach list |
| JSON out | struct → `serde_json::to_string` → `String` → `Body` | bajty do reużywanego `Vec<u8>`, `itoa` | 2–5× na serializacji |
| JSON in | `serde_json::Value` | `#[serde(borrow)] Cow<'a, str>`, tylko potrzebne pola | 3–10× na parsowaniu |
| JWT | `jsonwebtoken::decode` z `Validation` per żądanie | `Hmac` z kluczem przygotowanym raz, `clone()` per token, podpis przed JSON | 2× na auth |
| Nagłówki/formatowanie | `format!`, `HeaderMap::insert` | `extend_from_slice(b"...")`, `itoa` | małe, ale zero alokacji |
| Pamięć per połączenie | domyślne bufory hyper (8 KB+) | limit keep-alive (`Connection: close` ponad N), `http1::Builder::max_buf_size`, lub io_uring provided buffers | ×10–20 mniej RSS przy dużym keep-alive |
| Checkpoint WAL | automatyczny (w środku COMMIT) | `wal_autocheckpoint=0` + PASSIVE między paczkami | p99 zapisów stabilne |
| Build | domyślny release | fat LTO, 1 CGU, abort, `target-cpu`, własne SQLite z `THREADSAFE=0` + PGO | 10–30 % globalnie |

---

## 6. Trzy zadania praktyczne (refactoring kata)

Do każdego: sklonuj repo, `git fetch origin refs/pull/N/head:prN`, `git checkout prN`, pracuj w `submissions/<...>`. Testy poprawności: `bash test/run.sh submissions/<katalog>` (42 sprawdzenia). Benchmark lokalny: `wrk`/`oha` na `/feed` i `/posts/:id`, albo `k6 run -e VUS=2000 bench/load.js`.

### Kata 1 — Zero-alloc feed w Axum (PR #22, `rust-axum-SvetlinZarev`)

Cel: `GET /feed` bez `Vec<Post>`, bez `String` per kolumna i bez `serde_json`.

1. W `src/db.rs` dodaj strukturę `ReadStmts` z `Statement` dla `SQL_FEED` i `SQL_POST_BY_ID` trzymaną w `thread_local!` obok `READ_CONN` (albo użyj `prepare_cached` i podnieś pojemność cache).
2. Przenieś `json_string` i `number` z `rust-epoll-scooter1337/src/main.rs` (wersja skalarna, bez SIMD) do `src/response.rs`.
3. Przepisz `api/feed.rs`: `let mut out = Vec::with_capacity(4096); out.extend_from_slice(b"{\"posts\":[");` → pętla `while let Some(row) = rows.next()?` z `row.get_ref(1)?.as_bytes()?` → `Response::builder().header(CONTENT_TYPE, "application/json").body(Body::from(out))`.
4. Usuń `Post::from_row`, `FeedResponse`, `PostResponse`.
5. Zmierz `oha -c 100 -z 15s http://127.0.0.1:3000/feed` przed i po; porównaj liczbę alokacji przez `heaptrack` lub `valgrind --tool=dhat` dla 1000 żądań. Cel: ≥ 1.5× req/s, < 5 alokacji per żądanie (hyper i tak kilka zrobi).

### Kata 2 — Group commit „per tick” w Axum (PR #22)

Cel: zamienić writer w `db.rs` tak, by odczyty i zapisy z jednej iteracji dzieliły transakcję, a odpowiedzi wychodziły po COMMIT — jak w `uring.rs::run` + `flush`.

1. Zmień runtime na `#[tokio::main(flavor = "current_thread")]` i zastąp `std::thread::spawn(writer_loop)` zadaniem Tokio z `yield_now().await` po pierwszym `recv` (wzór: `rust-axum-tbsvttr/src/main.rs::work`).
2. Rozszerz `enum Write` o warianty odczytu (`Feed { done }`, `Post { id, done }`) i przepuść *wszystkie* żądania przez aktora, tak by miały jedno połączenie i jedno `BEGIN` (deferred) na paczkę. Zacznij transakcję przy pierwszym zapytaniu, nie tylko przy zapisie (`db.rs::begin` zwycięzcy).
3. Dodaj odpowiednik `Pending`: wektor `(oneshot::Sender, Reply)`, który po `COMMIT` wysyła odpowiedzi, a po błędzie — 500 dla wszystkich.
4. Dodaj `PRAGMA wal_autocheckpoint=0` i `wal_checkpoint(PASSIVE)` po wysyłce odpowiedzi, gdy `rx.is_empty()`.
5. Test: `python3 submissions/rust-axum-tbsvttr/tests/commit_check.py` (inżekcja błędu commit) musi przechodzić; `wrk -s submissions/rust-axum-tbsvttr/bench.lua` pokaże wzrost req/s w miksie z zapisami. Zadanie dodatkowe: zmierz, co się dzieje z p99, gdy zamiast `yield_now` użyjesz `sleep(1ms)` jako okna batchingu.

### Kata 3 — Odchudź połączenie: z 24 B do 16 B i z powrotem (PR #19, `rust-epoll-scooter1337`)

Cel: zweryfikować tezę z 4.2 pkt 3, że `Buffer` można zastąpić `Vec<u8>` bez mierzalnej straty — i nauczyć się mierzyć, zanim się optymalizuje.

1. W `src/uring.rs` zamień `struct Buffer` na `Vec<u8>` (`extend` → `extend_from_slice`, `consume` → `drain(..n)`, `reserve` zostaje). Usuń `const _: () = assert!(size_of::<Client>() == 64)` i wypisz nowy rozmiar.
2. Zachowaj niezmiennik „`flight` nie rośnie, gdy send jest w locie” — teraz wymusza go to, że `flight` nigdy nie jest `extend`-owany (dodaj `debug_assert!`).
3. Usuń `unsafe` z `Buffer::bytes/extend/consume/Drop` (powinno zniknąć ~6 bloków).
4. `cargo test --release -- --ignored --nocapture` z `CHECK_TOKEN` (test alokacji) musi dalej raportować 0 alokacji w hot path.
5. Zmierz: `wrk -t2 -c64 -d20s` na `/feed` i `/posts/1` ×4 w porządku AB/BA/BA/AB (jak w `IO_URING.md`); potem `python3 tests/check.py --connections 80000` i porównaj RSS (`/proc/<pid>/status` → `VmRSS`). Zapisz wnioski w stylu `IO_URING.md`: mediana, min–max, czy różnica przekracza szum. Spodziewany wynik: różnica w szumie dla req/s, kilkaset KB różnicy w RSS przy 80k połączeń.

---

## Dodatek A — jak odtworzyć analizę

```bash
git clone --depth 1 https://github.com/arjaythedev/twelve-dollar-server-challenge.git
cd twelve-dollar-server-challenge
git fetch --depth 1 origin 'refs/pull/*/head:refs/remotes/pr/*'
for pr in 19 17 22 32 25 46; do git ls-tree --name-only pr/$pr submissions/; done
git archive pr/19 submissions/rust-epoll-scooter1337 | tar -x -C /tmp/subs
```

## Dodatek B — mapa plików zwycięzcy

| Plik | Co zawiera | Najważniejsze funkcje |
|---|---|---|
| `src/uring.rs` | ring, worker, pętla, bufory, backpressure, 64-bajtowy `Client` | `Worker::new`, `run`, `process`, `on_accept/on_recv/on_send`, `flush`, `response`, `tag` |
| `src/main.rs` | JSON writer (`json_string`, `plain16`), `Auth` (HS256), `frame` (HTTP), `BodySeed`, `App::serve` | `Auth::user`, `frame`, `App::serve` |
| `src/db.rs` | FFI SQLite, prepared statements, deferred transaction, checkpoint, `range_feed` | `Db::open`, `begin/commit/checkpoint`, `read`, `range_feed`, `create`, `like`, `append_post_with_likes` |
| `src/net.rs` | ścieżka epoll (`--epoll`) z arena-buforem i tą samą logiką `Pending` | `run` |
| `build.rs` | kompilacja SQLite z flagami i PGO | — |
| `IO_URING.md`, `BENCHMARKS.md` | metodologia pomiarów, profile `perf`, odrzucone eksperymenty | — |
