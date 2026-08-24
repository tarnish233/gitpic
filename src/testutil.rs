//! Test-only helpers for the two modules that speak HTTP.
//!
//! `github` and `release` both test against a loopback stub rather than the network (see
//! AGENTS.md: the crate's tests never reach out), and both need the same three things — a
//! one-shot server, a canned response, and a *correct* request reader.
//!
//! The reader is why this module exists rather than each test rolling its own. `release`'s
//! stub did roll its own, with a single `sock.read`, which is the exact bug the commit
//! before it deleted from `github` — and there the consequence was worse than flakiness: its
//! assertion is that the update check sends **no** `Authorization` header, and a truncated
//! read satisfies that by never having read the header block at all. A security assertion
//! that passes because it looked at nothing is worse than no assertion, because it reads
//! like cover.
//!
//! Declared `#[cfg(test)] mod testutil;` in `main.rs`, so none of it exists in a release
//! build.

/// Single-connection stub server. Returns the bound address and a handle that yields the raw
/// request text once served, one entry per response given.
pub(crate) fn stub(responses: Vec<String>) -> (String, std::thread::JoinHandle<Vec<String>>) {
    use std::io::Write;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = format!("http://{}", listener.local_addr().unwrap());
    let handle = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for body in responses {
            let (mut sock, _) = listener.accept().unwrap();
            seen.push(read_request(&mut sock));
            let _ = sock.write_all(body.as_bytes());
            let _ = sock.flush();
        }
        seen
    });
    (addr, handle)
}

/// A JSON response with the headers `reqwest` needs to consider it complete.
pub(crate) fn http(status: &str, json: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{json}",
        json.len()
    )
}

/// Read one whole HTTP request: the headers, then exactly the body `Content-Length` promises.
///
/// **One `read` is not enough**, and that is worth spelling out because the single
/// `sock.read` this replaced looked entirely reasonable. TCP is a stream, not a message
/// queue: `reqwest` writes the headers and the body as separate segments, so one `read`
/// frequently returns the headers alone. Measured before the fix,
/// `put_file_sends_the_existing_sha_when_overwriting` failed about two runs in five.
///
/// It stayed hidden because that was the only test asserting on a request *body*. Every
/// other assertion is against the request line or a header, which are always in the first
/// segment — so the bug was invisible to all of them, and to that one too on any run that
/// happened to pass. `release`'s own stub then reintroduced it, where a partial read would
/// have made its "no credential is sent" assertion pass vacuously.
fn read_request(sock: &mut std::net::TcpStream) -> String {
    use std::io::Read;
    let mut raw: Vec<u8> = Vec::new();
    let mut buf = [0u8; 8192];

    // The headers end at the blank line. Reading until it is found, rather than
    // assuming one segment holds it, is the whole point of this function.
    let head_end = loop {
        if let Some(i) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        match sock.read(&mut buf) {
            // Peer hung up mid-headers: hand back what arrived and let the calling
            // test's assertion name the mismatch.
            Ok(0) | Err(_) => return String::from_utf8_lossy(&raw).to_string(),
            Ok(n) => raw.extend_from_slice(&buf[..n]),
        }
    };

    // Then exactly as many body bytes as the headers promised. A request with no
    // `Content-Length` — every GET in these tests — is already whole at `head_end`.
    let want = std::str::from_utf8(&raw[..head_end])
        .ok()
        .and_then(|head| {
            head.lines().find_map(|line| {
                let (name, value) = line.split_once(':')?;
                // Case-insensitively, because HTTP header names are — pinning
                // `reqwest`'s current capitalisation would be a second thing to get
                // wrong later.
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim())
            })
        })
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);

    while raw.len() < head_end + want {
        match sock.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => raw.extend_from_slice(&buf[..n]),
        }
    }
    String::from_utf8_lossy(&raw).to_string()
}
