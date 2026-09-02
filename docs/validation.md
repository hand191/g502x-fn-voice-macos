# Validation record

- Date: 2026-09-02
- Version: 0.3.2 (build 5)

## Tested environment

- Logitech G502 X, USB vendor/product `046d:c099`
- G6 / DPI Shift input usage `5`
- macOS 15 SDK runtime environment
- Doubao Input Method 0.9.7

## Automated checks

- HID Fn report shape and descriptor tests
- Release state-machine ordering, duplicate-signal, cleanup, failure, and
  rapid-repress tests
- Text-selection policy tests for insertion points, non-empty replacement
  ranges, invalid ranges, and integer overflow
- Clean public package result: 12/12 tests passed, followed by a successful
  release build and signed-app packaging check

Run them with:

```sh
swift test
```

## Manual acceptance: 0.3.2

The installed 0.3.2 build passed three focused end-use regressions:

- A non-empty selection in an editable chat field was replaced once; release
  stopped recognition immediately; the insertion point and pointer stayed put.
- A fully selected Chrome address bar was replaced once; release stopped
  recognition immediately; the page did not navigate and the app remained
  connected.
- A normal collapsed insertion point still inserted text once; release stopped
  recognition immediately; the insertion point and pointer stayed put.

Unified logs for the accepted cycles showed one Fn-down, one isolated stop
click, and one Fn-up cleanup, with no reconnect or stop failure.

## Previous stability baseline: 0.3.1

The installed 0.3.1 build passed all of the final end-use checks:

- 5 short-utterance cycles
- 5 longer-utterance cycles
- 2 final mixed-length cycles

Every accepted cycle met the same visible criteria:

- voice recognition started immediately on G6 down;
- recognition stopped immediately after G6 release;
- text was inserted once;
- the insertion point and mouse pointer stayed in place.

This is evidence for the hardware/software combination above, not a general
compatibility claim for other G502 variants or input methods.
