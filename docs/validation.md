# Validation record

- Date: 2026-09-02
- Version: 0.3.1 (build 4)

## Tested environment

- Logitech G502 X, USB vendor/product `046d:c099`
- G6 / DPI Shift input usage `5`
- macOS 15 SDK runtime environment
- Doubao Input Method 0.9.7

## Automated checks

- HID Fn report shape and descriptor tests
- Release state-machine ordering, duplicate-signal, cleanup, failure, and
  rapid-repress tests
- Clean public package result: 10/10 tests passed, followed by a successful
  release build and signed-app packaging check

Run them with:

```sh
swift test
```

## Manual acceptance

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
