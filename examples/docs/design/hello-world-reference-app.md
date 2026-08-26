# HelloWorld example — what it demonstrates

A minimal pub/sub example, implemented identically across all four zzdds
bindings (Zig native, C, C++, Java): one keyless topic, fixed RELIABLE +
KEEP_ALL QoS, and a reader-ready-gated write loop. Where `shape` is a
configurable diagnostic tool with a large CLI surface, this is the opposite:
the smallest complete example worth reading start to finish, with nothing
configurable beyond a domain override.

It's also the one example built specifically around
`DataWriterListenerEx::on_reliable_reader_ready` — every other example in
this repo either doesn't exercise that listener extension or only does so
indirectly.

## The type

```idl
@appendable
struct HelloWorld {
    int32 count;
    string<256> message;
};
```

Topic name `HelloWorld`. Deliberately keyless — DDS treats a keyless topic's
data as a single instance, which matches this example's shape exactly (one
publisher, one subscriber, one logical instance, no key needed).

## QoS

`RELIABLE` reliability, `VOLATILE` durability (the default), `KEEP_ALL`
history, on both sides — fixed, not configurable. "Reliable means you get
everything" stays literally true with no history-depth number to explain.

## Publisher flow

1. Create participant → register `HelloWorld`'s TypeSupport → topic →
   publisher → DataWriter.
2. Install a listener that tracks two things: `on_reliable_reader_ready`
   (fires once a matched reader has completed the RELIABLE handshake, before
   any data can usefully be sent) and `on_publication_matched`'s
   `current_count`.
3. Wait for a reader to become ready, then write all 10 samples
   (`count` 0–9) back to back, with no pacing delay — RELIABLE absorbs the
   whole burst with zero drops.
4. Wait for `current_count` to drop back to 0 (the subscriber deleted its
   reader), then tear down and exit.

## Subscriber flow

1. Create participant → TypeSupport → topic → subscriber → DataReader with
   a listener on `on_data_available`.
2. In the callback, take each available sample and check `count` is exactly
   the next expected value in sequence (0, 1, 2, …) — a newcomer-friendly
   way to prove RELIABLE + KEEP_ALL really does deliver everything, in
   order, with no gaps.
3. After the 10th sample, delete the reader immediately (this is what drops
   the publisher's matched count to 0) and exit.

See each language's own README for build and run instructions.
