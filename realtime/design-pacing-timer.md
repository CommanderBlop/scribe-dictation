# Design — pacing timer (practice mode)

> **Status: implemented** on branch `feature/pacing-timer`. Schema confirmed against
> the ElevenLabs docs — `committed_transcript_with_timestamps` carries a `words`
> array of `{ text, start, end (seconds), type: "word"|"spacing", speaker_id }`, and
> the word timestamps require the `include_timestamps=true` query param (which the
> engine now sets whenever the timer is on). Engine: `--timer` / `--timer-interval`.
> Glue toggles: mac `M.timer` / `M.timerIntervalSecs`; Windows `TIMER` /
> `TIMER_INTERVAL`. All default off.

**Goal:** while practicing interviews / public speaking with realtime dictation,
drop a minute marker into the transcript every N seconds, so afterwards you can see
how many words you spoke in each minute (a rough WPM / pacing read).

Example output:

```
So the main challenge I faced was scaling the ingestion pipeline …
[1:00 · 132 words]
… we ended up sharding by tenant, which cut p99 latency in half …
[2:00 · 118 words]
```

Opt-in only (normal dictation shouldn't get timers in the text).

---

## The hard part (and the fix)

Committed transcription is **segment-at-a-time**: a segment only finalizes after a
VAD pause, then the whole chunk floods out at once. So if the 1:00 mark falls in the
*middle* of a segment you're still speaking, a naive "print the marker when a
wall-clock timer fires" lands the marker at the wrong place — the sentence that
straddles 1:00 gets attributed entirely to the wrong minute, and the marker snaps to
whatever segment boundary happens to be nearby.

**Fix: don't use the wall clock to place the marker — use the word timestamps the
API already gives us.** The `committed_transcript_with_timestamps` message carries
per-word timing relative to the audio stream. So for each finalized segment we know
the audio-time of every word, and we can split the segment *at the exact word* whose
timestamp crosses the minute boundary:

```
segment "we ended up sharding by tenant which cut latency"
words:    …  by[58.9s]  tenant[59.4s] | which[60.2s]  cut[60.6s] …
                                    ^ 60s boundary
=> emit "we ended up sharding by tenant"
   emit "[1:00 · 132 words]"
   emit "which cut latency"
```

Because sox streams continuously (no gaps), audio-time ≈ elapsed real time since you
started, *including your pauses* — which is exactly the denominator you want for
"words per minute of the session."

### The one honest caveat

A segment only commits **after** you pause. So at real-time 1:00, while you're
mid-sentence, nothing appears on screen yet; when you pause at ~1:08 the whole
segment commits and we *retroactively* insert `[1:00 …]` at the correct word inside it.

- **Position in the text is exact** (correct word boundary, correct per-minute word
  counts) — this is what matters for reviewing pacing afterward.
- **On-screen appearance is delayed to the commit** — inherent to committed
  transcription; can't be avoided without pasting at the wrong position.

If a *live* "ding at exactly 1:00" feel is wanted too, that's a separate, out-of-band
signal (tray tip / sound) driven by a plain wall-clock timer in the glue — it doesn't
touch the transcript. See "Live tick" below. The two can coexist.

---

## Where it lives

All in the **engine** (`realtime/scribe_stream.py`, `receive()`), so **both**
platforms get it free and the glue needs zero changes: the marker is just another
finalized line emitted on the `--emit` stream / `--out-file`, and AHK / Hammerspoon
paste it like any other segment.

## Interface

- `--timer` — enable minute markers (default off).
- `--timer-interval SECS` — default `60`.
- Glue config toggle: AHK `TIMER := true`, Hammerspoon `M.timer = true` (both off by
  default). Only the practice binding turns it on.

## Marker format

One distinct, easy-to-strip line: `[M:SS · <n> words]` where `<n>` is words *in the
minute just ended*. (Could also show cumulative / running avg — keep to one line.)

## Word counting (bilingual!)

This is a mixed CJK/English tool, so `text.split()` under-counts Chinese (no spaces).
Count = (Latin/number word-runs) + (each CJK codepoint as 1). Small helper:

```python
import regex  # or a hand-rolled scan over unicodedata ranges
def count_words(s: str) -> int:
    cjk = sum(1 for ch in s if '㐀' <= ch <= '鿿' or '豈' <= ch <= '﫿')
    latin = len(re.findall(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*", s))
    return cjk + latin
```

## Algorithm sketch (in `receive`)

```
next_mark = interval           # seconds; e.g. 60, 120, …
words_since_mark = 0
on each committed_transcript_with_timestamps with words[]:
    seg_words = [(w.text, w.start, w.end) for w in m["words"]]   # confirm field names
    if timer enabled and any word crosses next_mark:
        while seg_words and next_mark <= seg_words[-1].end:
            before = words with start <  next_mark
            after  = words with start >= next_mark
            emit(text(before)); words_since_mark += count_words(text(before))
            emit(f"[{mmss(next_mark)} · {words_since_mark} words]")
            words_since_mark = 0
            next_mark += interval
            seg_words = after
        emit(text(seg_words)); words_since_mark += count_words(text(seg_words))
    else:
        emit(text); words_since_mark += count_words(text)
```

Handles multiple boundaries inside one long segment (loop), and long silences
(several marks may print together when the next segment finally commits — acceptable;
could optionally collapse).

## To confirm before coding

The exact shape of `committed_transcript_with_timestamps` — the words array key
(`words`? `timestamps`?) and per-word fields (`text`/`word`, `start`/`end`, seconds
vs ms). Log one raw frame (we already have a stderr path) and read it once.
**Fallback:** if timestamps are absent/unexpected, degrade to wall-clock placement
(marker between segments) so the feature still works, just less precisely.

## Live tick (optional add-on, separate)

For a metronome feel independent of speech: a wall-clock timer in the glue that every
N seconds shows a tray tip (Windows) / small HUD (mac) and/or a soft sound. Pure
out-of-band; never edits the transcript. Cheap to add if wanted.
