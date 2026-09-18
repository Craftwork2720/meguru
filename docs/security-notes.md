# Security notes

How credentials are redacted on the way into markers and log lines, what round-trips through `settings/opds.lua`, and what is deliberately never scrubbed.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Security notes

- **No secret is in a marker file, and `Marker.saveAt` is what enforces it.**
  `server_name` is a catalog title; Kavita's API key is a path segment of the stream
  template **and of every feed** — but in the **query** of the artwork
  (`/api/image/series-cover?…&apiKey=…`). Both positions are redacted, by the two rules
  in `Credential.redactTemplate`, so all three URL fields go to disk as `<redacted>` and
  come back through `Marker.load` from `settings/opds.lua`. One list
  (`CREDENTIAL_FIELDS`) names the fields both halves walk, so a URL field added to
  `Marker.new` cannot be redacted out and forgotten back — and one *list of positions*
  is what the `apiKey` rule was missing when covers were first declared covered.
  `restoreTemplate`'s guard is an **origin** comparison, not a prefix one, because the
  cover's prefix (`…/api/image/…`) has nothing in common with the root's
  (`…/api/opds/…`); it still refuses a key whose catalogue has moved to another host.
- **On Komga the same machinery redacts an API version, and that is not a bug to
  fix.** Komga authenticates with HTTP Basic, so there is no secret in any of its
  URLs — but its paths read `…/opds/v1.2/books/…`, and `Credential.redactTemplate`
  replaces whatever sits after `/opds/`, because on Kavita that is the key. So a
  Komga marker stores `…/opds/<redacted>/books/…` and `Marker.load` puts `v1.2`
  back. It round-trips, for the reason that module gives: the positional rule
  replaces only what it can name and names it back the same way, and the prefix
  guard refuses when the catalogue root has moved. Teaching it to skip a segment
  that *looks* like a version would be the guess `credential.lua` argues against.
- **A marker written before that pair existed still carries the key, forever.** Markers
  are not scrubbed in place: rewriting a book file the reader did not ask to have
  rewritten is worse than a stale copy in a folder they control. So "markers hold no
  secret" is true of new ones; delete and re-add the old books if it matters.
- **`crash.log` is a file too, and `Net.redactUrl` is the only thing a log line may print
  a URL through.** It strips the credential-bearing path segment, so the four failure
  lines in `Net.get` never write Kavita's key out on a 404. The query is reduced to its
  byte count and `user:pass@host` never reaches the output; both are load-bearing and
  neither should be "simplified". The one place that had escaped this — `noteFeed`'s
  `feed parsed` line, which printed the browsed catalog URL raw — now goes through it
  too.
- **Credentials are read from `settings/opds.lua` and go nowhere else.** A marker with a
  `<redacted>` field resolves the credential at load so the book can be read at all;
  nothing sends one except a page fetch and, on Komga, the position report.
- **The position report is the one thing this plugin sends *to* a server.** A page number,
  to the server the book came from, with the credential in the same Basic header a page
  fetch already sends — so the write adds no new place a secret can appear.
- **Nothing the server answers is logged, and that is deliberate.** Komga's refusal text
  is genuinely useful (`400 Page number does not exist` is the sentence that catches a
  numbering mistake), and it is still not printed: `crash.log` is a file routinely pasted
  into a bug report, a response is text nobody here controls, and a misconfigured proxy
  echoing the request it just proxied would put the Basic header into it. The status code
  and the URL through `Net.redactUrl` place every failure this feature can have.
- The derived `catalogURL` is never stored — it is built at call time from
  `settings/opds.lua` and kept in a local. Every URL that does reach a log line goes
  through `Net.redactUrl`.
- Kavita's stream `template` in a marker unavoidably embeds the API key; that is what
  opens the book. It is bounded to that one field in a file the reader controls, and to
  `settings/opds.lua`, where the key already lives. The markers that carry it in
  plaintext are the ones written before the redaction pair existed; nothing scrubs them,
  by the rule above.
- `settings/opds.lua` is read **only**, never written.
