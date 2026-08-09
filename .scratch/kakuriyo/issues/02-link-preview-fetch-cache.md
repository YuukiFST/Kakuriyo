# Link Preview fetch and local cache

Type: research
Status: resolved
Blocked by:

## Question

How should Kakuriyo implement **Preview** for Entries that have a URL: fetch Open Graph / similar metadata when online, **cache on disk**, work offline from cache, with **no telemetry** and minimal privacy leakage (what is sent to remote hosts, referrer, user-agent)? What Rust crates or patterns fit a local gpui/desktop app?

## Answer

Use **reqwest** (`.referer(false)`, short `Kakuriyo/x.y` UA, no cookies) to GET the Entry URL; parse with **`webpage` (`default-features = false`) `HTML::from_string`**; resolve **OG → Twitter meta → HTML title/description**; store Preview (+ optional image) **in the encrypted Vault** for offline; never use a third-party unfurl API. Full write-up: [research/02-link-preview-fetch-cache.md](../research/02-link-preview-fetch-cache.md).
