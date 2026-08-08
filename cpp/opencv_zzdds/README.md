# opencv_zzdds

Video capture → ROI detection → display, streamed over DDS using the zzdds
C++ bindings and OpenCV. Three programs:

- `video_capture` — captures from a V4L2 camera, publishes `ovidds::Frame`
  samples on the `ovidds_frames` topic (domain 4).
- `video_roi_display` — subscribes to `ovidds_frames`, shows the video in an
  OpenCV window.
- `roi_generator` — standalone face-detection demo (`DetectionBasedTracker`),
  no DDS involvement.

Reliability is explicitly set to `RELIABLE` on both the DataWriter and
DataReader. This isn't optional: a `Frame` at 640x480x3 is ~900KB, fragmented
into hundreds of RTPS/UDP datagrams, and under the default `BEST_EFFORT` a
single dropped fragment silently loses the entire sample — no full
reassembly, ever. Worth remembering if you copy this pattern for another
large/unbounded-sample type: `BEST_EFFORT` is fine for small samples, but
the larger and more fragmented a sample gets, the more a single lost
datagram costs you.

## Build and run

```sh
zig build -Dc-binding -Dcpp-binding install --prefix $ZZDDS_ROOT   # in zzdds/
cmake -B build -DZZDDS_ROOT=$ZZDDS_ROOT
cmake --build build
cd build
./video_roi_display &
./video_capture
```

## No camera / no display (CI)

Both programs work without real hardware:

- `video_capture`: if the real camera fails to open, or `OVIDDS_MOCK_CAMERA=1`
  is set, it falls back to a synthetic frame source (a cycling solid color
  plus a frame-number text overlay, at a fixed 640x480) instead of exiting —
  enough to exercise the real DDS write/fragment path deterministically.
- `video_roi_display`: if `$DISPLAY` isn't set, or `OVIDDS_HEADLESS=1` is set,
  it skips `imshow`/`waitKey` (which abort rather than fail gracefully with no
  GUI backend) and instead logs periodic — not per-frame — stats (every 5s)
  showing frames received.
- `OVIDDS_RUN_SECONDS=<n>` bounds either program's runtime instead of waiting
  on an interactive stdin line (`video_capture`) or a 'q'/ESC keypress in a
  window that doesn't exist (`video_roi_display`).

`smoke_test.py` (needs Python 3.10+) builds both and runs this combination
end to end, checking that frames actually got delivered (not just that the
processes exited 0):

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./smoke_test.py
```

`roi_generator` still needs a real camera and display — it's a standalone
demo, not part of the DDS path this smoke test exercises.
