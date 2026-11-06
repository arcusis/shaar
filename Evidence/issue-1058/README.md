# Lazy background tab evidence

The hidden #1108 footprint runner used the same verification bundle and pinned
shaar.17 engine in both modes. `--eager` reproduces the old measurement probe's
policy; the default uses the shipping window's lazy policy. Each case sampled
the app and descendant processes for 15 seconds after readiness.

| Saved tabs | Eager RSS / processes | Lazy RSS / processes | Lazy placeholders |
| ---: | ---: | ---: | ---: |
| 1 | 1,274.4 MiB / 9.9 | 1,295.2 MiB / 10.0 | 0 |
| 10 | 2,492.7 MiB / 19.0 | 1,292.2 MiB / 10.0 | 9 |
| 30 | 5,159.2 MiB / 39.0 | 1,294.5 MiB / 10.0 | 29 |

Raw results: [eager](footprint-eager.json) and [lazy](footprint-lazy.json).
The 10 and 30 tab lazy cases saved 1,200.5 MiB (48.2%) and 3,864.7 MiB
(74.9%) relative to eager mode. The 1 tab result did not materially differ.
These are one matched run per mode. Eager readiness waits for every page; lazy
readiness waits for the selected page and checks the remaining placeholders, so
the launch times have different endpoints. Host load made idle CPU variable.
The shipping app already used lazy restoration before this change; the measured
RSS reduction is evidence for that policy, not a new release-to-release gain.

Run from the repository root with the signed verification bundle installed:

```sh
nice -n 10 python3 scripts/measure-footprint.py --eager --output build/footprint-eager.json
nice -n 10 python3 scripts/measure-footprint.py --output build/footprint-lazy.json
```

The sidebar captures show a saved ordinary background tab before and after its
favicon is cached, with no engine tab attached. They were rendered through
`MountedChromeSidebar` in a hidden AppKit window with no physical input or
visible desktop window. The first image shows the generic globe; the second
shows the cached icon while retaining the saved title.

![Before cached icon](before-placeholder-icon.png)

![After cached icon](after-placeholder-icon.png)

The screenshots establish the placeholder presentation only. The hidden native
probe and focused tests cover materialization behavior separately.
