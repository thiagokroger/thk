---
name: _capture-jam
description: Exhaustively capture a Jam.dev recording via the Jam MCP — details, metadata, video transcript and analysis (if video), every screenshot, every console log, every network request, and user events — into the session's context/jam/<jam-id>/ folder. For video jams, downloads the raw recording (WebM/MP4) via Jam's GraphQL API using a personal access token, and ffmpeg-extracts frames at every WebVTT cue (or every analyzeVideo action timestamp when the mic was off). transcript.md interleaves cues with `![t=…](./screenshots/…png)` so a reviewer can jump from a spoken line to the exact frame.
---

# Capture Jam

Downloads every available data point from a Jam recording via the Jam MCP. Writes to `<contextDir>/jam/<jam-id>/`. Verbatim — no summarization. For video jams, also pulls the raw recording over HTTPS and slices it into transcript-aligned PNGs with ffmpeg.

## Inputs

- `jamUrl` — the Jam recording URL.
- `contextDir` — absolute path to the session's context folder.

## Required tooling

- `curl` — always.
- `ffmpeg` — only required for video jams. If missing, skip frame extraction and report `framesAvailable: false`.
- A Jam personal access token, used **only** to query GraphQL for the media URL. The CDN URL itself is unsigned/public, so the token never gets near the bytes. Token lookup order (first hit wins):
  1. env var `JAM_TOKEN`
  2. file `<workdir>/.thk/keys/jam.key` — written by `install.sh` when Jam capture is selected, chmod 600 (with the `keys/` directory chmod 700)
  3. file `~/.jamtoken` — user-global fallback

  If no token is found on a video jam, skip the download and report `framesAvailable: false` with `reason: "no JAM_TOKEN"`. Capture-jam still produces details / transcript / analysis / logs / network without the token — the token only gates frame extraction.

## What's captured

- **Details** (overview, bug type) — always.
- **Metadata** — if available.
- **Video recordings**: full WebVTT transcript (with cue timestamps) + analysis (intents, actions, findings — each carrying `timestamp_ms`).
- **Raw video file**: WebM or MP4 saved to `video/recording.<ext>` for video jams (so re-extraction is offline-cheap).
- **Screenshots**:
  - Video jams → ffmpeg-extracted frames at WebVTT cue starts (or `analyzeVideo` action timestamps when no transcript).
  - Screenshot jams → frames returned by `mcp__Jam__getScreenshots`.
- **Console logs** — **every** entry, not just errors.
- **Network requests** — **every** request, not just failures.
- **User events** — if available.

## Procedure

1. `mcp__Jam__getDetails` — overview + bug type. Determines video vs screenshot.
2. `mcp__Jam__getMetadata` — metadata if available.
3. If **video**:
   - `mcp__Jam__analyzeVideo` — intents + actions + findings (each carries `timestamp_ms`).
   - `mcp__Jam__getVideoTranscript` — full WebVTT transcript with cue timestamps.
4. `mcp__Jam__getConsoleLogs` — every entry, chronological.
5. `mcp__Jam__getNetworkRequests` — every request, chronological (status, URL, method, timing).
6. `mcp__Jam__getUserEvents` — if available.
7. **Frames for video jams** — only if a `JAM_TOKEN` is available *and* `ffmpeg` is installed:
   1. POST to Jam's GraphQL endpoint to get the CDN media URL:
      ```bash
      curl -sL -H "Authorization: Bearer $JAM_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST "https://graphql.jam.dev/graphql?op=jamMedia" \
        -d '{"query":"query jamMedia($id: String!){ jam(id: $id){ ... on VideoJam { data { media { url } } } } }","variables":{"id":"<jamId>"}}'
      ```
      Response shape: `data.jam.data.media.url` → e.g. `https://cdn-jam-screenshots.jam.dev/<hash>/video/<uuid>.webm`. The CDN URL is unsigned — no Authorization header on the download.
   2. Download to `<contextDir>/jam/<jam-id>/video/recording.<ext>` (extension derived from the URL's suffix).
   3. Build the **extraction grid**:
      - If a transcript exists → use the start time of every WebVTT cue.
      - Else → use every `timestamp_ms` from `analyzeVideo` (intents.start_ms, actions.timestamp_ms, findings.timestamp_ms), de-duplicated and sorted ascending.
   4. For each timestamp `t` in the grid:
      ```bash
      ffmpeg -y -ss <HH:MM:SS.mmm> -i <video> -frames:v 1 -q:v 2 \
        <screenshots>/<HH-MM-SS-mmm>.png
      ```
      The dashed filename keeps files sorting chronologically.
8. **Frames for screenshot jams** — call `mcp__Jam__getScreenshots`. For each entry, `curl -sL -o <screenshots>/<NNN>.png <url>` using zero-padded sequence numbers. No timestamp prefix (screenshot jams aren't time-aligned).

Write under `<contextDir>/jam/<jam-id>/`:

- `details.md` — overview + metadata + token / ffmpeg presence flags.
- `transcript.md` — video only. WebVTT cues kept verbatim. After each cue whose time range overlaps a screenshot timestamp, append `![t=<HH:MM:SS.mmm>](./screenshots/<HH-MM-SS-mmm>.png)`. If a screenshot falls between cues, insert the reference on its own line at the chronologically correct position. Each frame must be referenced exactly once.
- `analysis.md` — video only; intents + findings. Where a finding/action cites `timestamp_ms`, append the matching `![t=…](./screenshots/…png)` reference inline. If a transcript was unavailable, this file becomes the primary narration — readers should still be able to follow the recording from analysis.md alone.
- `console.md` — full chronological logs.
- `network.md` — full chronological requests.
- `user-events.md` — if available.
- `video/recording.<ext>` — raw video file, video jams only (deletable after extraction; kept by default for re-runs).
- `screenshots/*.png` — frames named per step 7/8.
- `screenshots/index.md` — flat list mapping each filename to its timestamp (or sequence number for screenshot jams).

## Output

```
{
  jamId: string,
  type: "video" | "screenshot",
  screenshotCount: number,
  framesAvailable: boolean,            // true if frames are timestamp-aligned to transcript / analyzeVideo
  framesSource: "ffmpeg" | "mcp" | "none",
  videoDownloaded: boolean,            // video jams only — did the raw recording land on disk?
  reason?: string,                     // populated when framesAvailable=false (e.g. "no JAM_TOKEN", "ffmpeg missing")
  filesWritten: string[]
}
```

## Rules

- Capture every log and every request, not just errors / failures. Downstream analyzers decide what matters.
- Every screenshot must be on disk — never a URL reference in markdown.
- For video jams with `framesAvailable: true`, transcript.md must cross-reference every extracted frame by relative path. A reviewer reading the transcript should be able to click the closest frame at any spoken moment without consulting a separate index.
- The `JAM_TOKEN` is **only** sent to `graphql.jam.dev`. Never attach it to the CDN download (the URL is already unsigned) and never embed it in any captured markdown — mask it as `***` if it appears in network logs.
- Never fabricate timestamps. If a cue or action has no time, leave it out of the extraction grid; do not invent a `t=`.
- **Do not summarize.** Capture verbatim.
- If the Jam MCP is unavailable, return `{ error: "Jam MCP unreachable", jamUrl }` — do not proceed with partial data.
- If the GraphQL call returns an unexpected shape (Jam's schema may shift), capture the raw response under `video/graphql-debug.json` and continue with `framesAvailable: false`. Do not retry blindly.
