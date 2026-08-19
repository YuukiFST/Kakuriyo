# Research: Preview HTTP client in Rust

**Ticket:** [Which HTTP client preserves Preview privacy and budgets?](https://github.com/YuukiFST/Kakuriyo/issues/47)  
**Question:** Which client can fetch OG/Twitter/title with **no Referer**, Kakuriyo UA, **800 ms** budget, drop images **> 128 KiB**, TLS on NixOS, no WebView?  
**Sources:** `src/vault/preview.zig`, ureq / reqwest / soup3 docs.

---

## Verdict

Use **[`ureq`](https://docs.rs/ureq/latest/ureq/)** (blocking, cookies **off**, rustls + **platform-verifier**).

Do **not** use reqwest as the Preview client (default **Referer: true**, Tokio). Do **not** use libsoup/`soup3` (cookie jar, extra GNOME stack, no need).

Keep Zig’s parse order and caps: OG → Twitter → `<title>` / `description`; `max_body_bytes = 512 KiB`; `max_image_bytes = 128 KiB`; UA `Kakuriyo/0.1`; select path never fetches.

Run ureq on a **worker thread** (or Relm4 command), never on the GTK UI thread. 800 ms is a **deadline**, same as `fetchPreviewBudget`.

---

## What Zig does today

`src/vault/preview.zig`:

- `user_agent = "Kakuriyo/0.1"`
- `fetch_budget_ms = 800`
- GET via `std.http.Client`; extra header **only** `user-agent` (no Referer)
- `keep_alive = false`, redirect cap **3**
- Body cap `cap + 1` then `TooLarge` if over
- Image fetch uses the same GET with 128 KiB cap; oversize discarded (`acceptImageBytes`)

---

## ureq configuration

```rust
use std::time::Duration;
use ureq::Agent;
use ureq::tls::{TlsConfig, RootCerts};

let agent = Agent::config_builder()
    .timeout_global(Some(Duration::from_millis(800)))
    .user_agent("Kakuriyo/0.1")
    .max_redirects(3)
    .http_status_as_error(true)
    .tls_config(
        TlsConfig::builder()
            .root_certs(RootCerts::PlatformVerifier)
            .build(),
    )
    .build()
    .new_agent();
```

| Rule | How |
| --- | --- |
| No Referer | ureq does **not** add Referer. Do not set one. (reqwest *does* by default.) |
| No cookies | Default: cookies feature **off**. Never enable it for Preview. |
| UA | `user_agent("Kakuriyo/0.1")` — documented on `ConfigBuilder` |
| 800 ms | `timeout_global` covers DNS through body (ureq docs: end-to-end) |
| TLS / NixOS | Feature `platform-verifier` + `RootCerts::PlatformVerifier` uses OS trust (NixOS ca-bundle). Default webpki-roots is static and bypasses host store. |
| Image 128 KiB | Read body with a 128 KiB+1 cap; if more, drop image (match `acceptImageBytes`) |
| HTML 512 KiB | Same cap pattern |
| No WebView | Pure HTTP crate |

Default ureq features include **rustls** + gzip. Do not enable `cookies`. `native-tls` is opt-in on the agent only; prefer rustls + platform verifier.

Redirects: ureq default max redirects is 10; set **3** to match Zig.

Do not send `Accept` that implies a browser. Agent default `*/*` is fine; empty `""` also documented if we want no Accept.

---

## Why not the others

### reqwest

- Async + Tokio in a GTK app is extra runtime, or `reqwest::blocking` which still pulls that stack.
- [`ClientBuilder` Referer](https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html): **“Enable or disable automatic setting of the Referer header. Default is `true`.”** Easy to violate privacy if someone copies a default client.
- `timeout` exists and can be 800 ms; cookies default off — privacy is fixable, but ureq is the smaller match for a blocking budgeted GET.
- `relm4-components` optional WebImage uses reqwest — **do not** take that component.

### soup3 / libsoup

GNOME HTTP. Cookies and session semantics are the product default there. Extra `libsoup` in Nix. No WebView required, but no advantage over ureq for a privacy-minimal GET.

---

## HTML parse

Stay in Kakuriyo code (port `parseHtml`). Do not pull a browser HTML engine. Crate `scraper` is optional later; v1 can keep the Zig string scan.

---

## Sources (primary)

1. `src/vault/preview.zig` — UA, 800 ms, 128 KiB, 512 KiB, no Referer header, 3 redirects  
2. ureq crate (blocking, cookies off by default, rustls) — https://docs.rs/ureq/latest/ureq/  
3. ureq `timeout_global`, `user_agent`, `max_redirects` — https://docs.rs/ureq/latest/ureq/config/struct.ConfigBuilder.html  
4. ureq `RootCerts::PlatformVerifier` — same ureq docs, TLS section  
5. reqwest Referer default **true** — https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html  
6. soup3-rs — https://lib.rs/crates/soup3  
7. Product Preview rules — `.scratch/kakuriyo/research/02-link-preview-fetch-cache.md`
