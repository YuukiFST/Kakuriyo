# Research: Link Preview fetch and local cache

Ticket: [`issues/02-link-preview-fetch-cache.md`](../issues/02-link-preview-fetch-cache.md)  
Date: 2026-08-09  
Scope: Primary sources only (OGP, RFCs/W3C/WHATWG, crate docs, crate source).

## Verdict

Implement Preview as a **first-party fetch + parse + local store** pipeline: `reqwest` (privacy-tuned) GET of the Entry URL → parse HTML with **`webpage` (curl feature off) `HTML::from_string`** → resolve title/description/image from **Open Graph → Twitter Card meta → HTML `<title>` / `meta name=description`** → store the normalized Preview record (and optional image bytes) **on disk for offline use**, preferably **inside the encrypted Vault** (or encrypted with the Vault key), never via a third-party preview/telemetry API.

## What “Preview metadata” is

### Open Graph Protocol (canonical)

[ogp.me](https://ogp.me/) defines RDFa-style `<meta property="…" content="…">` in the document head. Required properties for a graph object: `og:title`, `og:type`, `og:image`, `og:url`. Generally recommended optionals include `og:description`, `og:site_name`, and structured `og:image:*` (`url`, `secure_url`, `type`, `width`, `height`, `alt`). URLs in OGP are `http`/`https` only. First of multiple same-property tags wins on conflict.

For Kakuriyo Previews, the useful minimum is: **title**, **description**, **image URL**, optional **site_name** / **type**.

### HTML fallbacks (WHATWG)

[HTML Living Standard — `meta name=description`](https://html.spec.whatwg.org/multipage/semantics.html#meta-description): a free-form string describing the page for directories / search; at most one per document. Pair with the document `<title>` when OG is absent.

### Twitter / X Cards (supplement)

Archived official Cards markup reference ([developer.twitter.com Cards markup via Wayback](https://web.archive.org/web/20230601000000id_/https://developer.twitter.com/en/docs/twitter-for-websites/cards/overview/markup)): tags such as `twitter:card`, `twitter:title`, `twitter:description`, `twitter:image` (and `twitter:image:alt`). Explicit rule: **if `og:type`, `og:title`, and `og:description` exist but `twitter:card` is absent, a summary card may still be rendered** — i.e. OG is the interoperability baseline; Twitter tags are an overlay / alternate.

**Resolution order for Kakuriyo:**

1. `og:title` / `og:description` / `og:image` (`og:image:secure_url` preferred when present) / `og:site_name`
2. Else `twitter:title` / `twitter:description` / `twitter:image`
3. Else HTML `<title>` + `meta name=description`
4. Else show hostname (or raw URL) with no image

Do not embed iframes/players (`twitter:player`, `og:video`) for v1 — Preview is a card, not an embed ([CONTEXT.md](../../../CONTEXT.md) language).

## Privacy: what a fetch actually reveals

Fetching an Entry URL **is** a network disclosure to that origin (and any redirect targets). Kakuriyo’s bar is **no telemetry / no third-party phone-home**, and **minimize accidental leakage** beyond the intentional GET.

### Sent to the remote host (unavoidable / inherent)

| Channel | Leak |
| --- | --- |
| TCP/TLS | Client IP; TLS SNI = hostname |
| Request line | Method + path + query of the stored URL (tokens in query strings are sent to the site) |
| `Host` | Authority (required by [RFC 9110 §7.2](https://www.rfc-editor.org/rfc/rfc9110.html)) |

### Headers Kakuriyo should control

**`Referer` — omit always.**  
[RFC 9110 §10.1.3](https://www.rfc-editor.org/rfc/rfc9110.html) documents Referer as a privacy concern (context / history / capability URLs). [W3C Referrer Policy](https://www.w3.org/TR/referrer-policy/) defines `"no-referrer"`: the `Referer` header is omitted.  

**Critical for Rust:** [reqwest `ClientBuilder::referer`](https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html) defaults to **`true`** (auto-set `Referer` on redirects). Set **`.referer(false)`** so a redirect chain does not attach the previous URL as Referer.

**`User-Agent` — short product id, no OS/browser fingerprint salad.**  
[RFC 9110 §10.1.5](https://www.rfc-editor.org/rfc/rfc9110.html): a UA SHOULD send `User-Agent` unless configured not to; SHOULD limit product identifiers; MUST NOT stuff advertising; SHOULD NOT send needlessly fine-grained detail (fingerprinting risk). reqwest’s docs example uses `CARGO_PKG_NAME/CARGO_PKG_VERSION`. Prefer e.g. `Kakuriyo/0.1` (or concat from package metadata). Do **not** spoof a full Chrome UA (lie + larger fingerprint surface). Do **not** append desktop OS/arch comments.

**Cookies — off.** reqwest has **no cookie store by default** ([`cookie_store`](https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html) is opt-in). Keep it that way so Preview never attaches browser session cookies.

**`From`, rich `Accept-Language`, custom analytics headers — do not send.** RFC 9110: `From` SHOULD NOT be sent without explicit user config; detailed Accept-Language can be identifying (§17 / privacy notes in the same RFC).

**No third-party preview proxy.** Any “link unfurl as a service” would receive the user’s private URLs (worse than talking to the destination alone) and conflicts with zero-telemetry.

### Redirects, TLS, size

- Follow redirects with a **low cap** (reqwest default max chain is 10; webpage’s curl path defaults to 5 — prefer ≤5).
- Prefer HTTPS; `https_only(true)` is available on reqwest if product policy wants it (blocks `http://` Entries’ Preview fetch — product call).
- Reject/avoid insecure TLS (`allow_insecure` / `danger_accept_invalid_certs` stay false).
- Cap response body (e.g. read only first N hundred KB of HTML) so Preview cannot be abused as a huge download.
- Optional hardening: refuse redirect targets / literal hosts in private IP ranges (link-local, RFC1918, etc.) to reduce SSRF-to-LAN surprises when an Entry URL is hostile.

### What is *not* sent if configured correctly

No Kakuriyo account id, Vault contents, Collection names, other Entry URLs, Master Password material, crash/analytics endpoints, or Referer from a previous page.

**Inherent residual risk (document in UI copy):** opening Preview while online tells that site (and observers on path) that *someone at this IP* requested that URL. Offline/cached Preview does not.

## Rust crates and patterns

### Recommended stack

| Role | Crate | Why (from primary docs/source) |
| --- | --- | --- |
| HTTP | **`reqwest`** (rustls-tls) | First-class `user_agent`, `referer(false)`, `redirect`, `https_only`, no cookies by default ([ClientBuilder](https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html), [redirect](https://docs.rs/reqwest/latest/reqwest/redirect/index.html)) |
| HTML / OG parse | **`webpage`** with **`default-features = false`** | `HTML::from_string` parses without fetching; fills `opengraph`, `title`, `description`, and flat `meta` map ([docs](https://docs.rs/webpage/latest/webpage/)); source stores both `property` and `name` meta into `meta`, and `og:*` into `Opengraph` ([webpage-rs `parser.rs`](https://github.com/orottier/webpage-rs)) |
| URL parse | **`url`** | Already a `webpage` dependency; validate scheme/host before fetch |
| Paths | **`dirs`** | `cache_dir()` → XDG cache / Windows Known Folder ([dirs 6](https://docs.rs/dirs/latest/dirs/)); aligns with [XDG `$XDG_CACHE_HOME`](https://specifications.freedesktop.org/basedir-spec/latest/) for *non-essential* cache if used |
| Serialize cache | **`serde` + `serde_json`** (or MessagePack) | Persist normalized Preview DTO |

### Use `webpage` for parse only — not `Webpage::from_url`

Upstream default fetch uses **libcurl** (`curl` feature, default on), default UA string **`webpage-rs - https://crates.io/crates/webpage`**, and does not expose reqwest-style Referer control ([Cargo.toml / `WebpageOptions` source](https://github.com/orottier/webpage-rs)). For privacy and one HTTP stack in a gpui app, **fetch with reqwest**, then:

```rust
let html = webpage::HTML::from_string(body, Some(final_url))?;
// title/description: html.opengraph.properties / html.opengraph.images
// fallbacks: html.meta.get("twitter:title"), html.title, html.description
```

Enable optional `webpage` feature `serde` only if useful.

### Alternatives (weaker fits)

| Crate | Notes |
| --- | --- |
| **`scraper`** | CSS selectors over html5ever ([docs](https://docs.rs/scraper/latest/scraper/)); fine if hand-rolling `meta[property^=og:]` — more code, same HTML engine family |
| **`opengraph` (crates.io)** | Last release **2018-10**, depends on **reqwest ^0.9**; abandoned for a 2026 app ([crates.io/opengraph](https://crates.io/crates/opengraph)) |
| **`cacache`** | Content-addressed disk cache ([docs](https://docs.rs/cacache/latest/cacache/)); overkill for small Preview JSON + one image per Entry |
| **`http-cache`** | HTTP caching middleware following cache rules; Preview needs an **app-level offline snapshot**, not full RFC 9111 intermediary semantics |

### Cache / freshness policy

[RFC 9111 §4.2](https://www.rfc-editor.org/rfc/rfc9111.html) defines freshness via `Cache-Control: max-age`, `Expires`, or heuristics. HTML pages often lack useful explicit freshness for “unfurl card” use. **Recommendation:** treat Preview as an **application cache** with a fixed TTL (e.g. 7–30 days) and explicit “Refresh Preview” — serve stale forever while offline; revalidate only when online and TTL expired or user-requested. Honor `no-store` only if you choose strictness; most bookmark-style apps ignore it for offline UX.

**Where to store (privacy-critical):**

1. **Preferred:** Preview DTO + image blob keyed by Entry id **inside the encrypted Vault** (survives offline, cleared with Vault wipe, no plaintext URL metadata in `~/.cache`).
2. **Acceptable secondary:** OS cache dir via `dirs::cache_dir()` / `$XDG_CACHE_HOME` for **image bytes only** if encrypted or treated as sensitive; plaintext cache of private Vault URLs weakens “encrypted at rest.”

XDG defines cache as **non-essential** data ([basedir-spec](https://specifications.freedesktop.org/basedir-spec/latest/)) — safe to delete; Vault-backed Preview should remain the source of truth for offline.

## Concrete architecture

```
Entry.url
   │
   ├─ offline / fresh cache hit → Preview DTO (+ image) from Vault
   │
   └─ online miss/stale → reqwest Client (shared)
         • user_agent("Kakuriyo/x.y")
         • referer(false)
         • redirect::Policy::limited(5)
         • timeout ~10s
         • no cookie_store
         • GET only; strip userinfo from URL (RFC 9110 warns on userinfo phishing)
         → body (size-capped) → webpage::HTML::from_string
         → normalize Preview { title, description, image_url, site_name, source_url, fetched_at }
         → optional second GET for image_url (same Client policy, MIME/size allowlist)
         → write Vault Preview record
```

**Trigger:** fetch when an Entry with URL is opened/selected and Vault is unlocked; never in background against the whole Vault without user intent (limits traffic + IP↔URL correlation blast radius).

**Failure:** soft-fail to hostname-only Preview; do not block Entry editing.

**gpui:** run fetch on a background task/thread; apply results on UI thread — no special HTTP crate beyond the above.

## Explicit non-goals

- No cloud unfurl API, no telemetry of fetch success/failure to Kakuriyo servers (there are none).
- No executing page JS (OG in SSR/`<head>` only; JS-only meta will miss — acceptable).
- No full browser engine / iframe Preview.

## Sources

1. Open Graph protocol — https://ogp.me/
2. WHATWG HTML — meta description — https://html.spec.whatwg.org/multipage/semantics.html#meta-description
3. Twitter Cards markup (archive of official docs) — https://web.archive.org/web/20230601000000id_/https://developer.twitter.com/en/docs/twitter-for-websites/cards/overview/markup
4. RFC 9110 — HTTP Semantics (`User-Agent`, `Referer`, Host) — https://www.rfc-editor.org/rfc/rfc9110.html
5. RFC 9111 — HTTP Caching (freshness) — https://www.rfc-editor.org/rfc/rfc9111.html
6. W3C Referrer Policy — https://www.w3.org/TR/referrer-policy/
7. reqwest `ClientBuilder` / redirect — https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html
8. webpage 2.0.1 docs + source (`HTML::from_string`, curl-optional fetch, OG/meta parsing) — https://docs.rs/webpage/latest/webpage/ · https://github.com/orottier/webpage-rs
9. scraper — https://docs.rs/scraper/latest/scraper/
10. dirs `cache_dir` — https://docs.rs/dirs/latest/dirs/
11. XDG Base Directory Spec — https://specifications.freedesktop.org/basedir-spec/latest/
12. opengraph crate (stale) — https://crates.io/crates/opengraph
13. Kakuriyo domain language — `Kakuriyo/CONTEXT.md`
