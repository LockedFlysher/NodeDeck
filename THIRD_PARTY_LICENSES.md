# Third-Party Licenses & Compliance Notes

NodeDeck's first-party Swift and Python source code is licensed under the **MIT License** (see `LICENSE`).
However, NodeDeck integrates and links against the following third-party open-source components:

| Component | Path / Artifact | Upstream Repository | License | Compliance Notes |
| :--- | :--- | :--- | :--- | :--- |
| **moonlight-common-c** | `Sources/CMoonlightCommon/src/` | https://github.com/moonlight-stream/moonlight-common-c | **GPL-3.0** | Copyleft. Binary distributions that statically link `CMoonlightCommon` into `NodeDeck` or `nodedeck-stream` are subject to GPL-3.0 terms for the combined binary, unless separated into an out-of-process helper binary. |
| **ENet** | `Sources/CMoonlightCommon/enet/` | https://github.com/cgutman/enet | **MIT** | Permissive; copyright notice preserved in source headers. |
| **nanors** | `Sources/CMoonlightCommon/nanors/` | https://github.com/sleepybishop/nanors | **MIT** | Permissive; copyright notice preserved in source headers. |
| **OpenSSL 3** | Linked statically / dynamically (`libcrypto`) | https://github.com/openssl/openssl | **Apache-2.0** | Compatible with GPL-3.0 and MIT. |
| **Opus** | Linked statically / dynamically (`libopus`) | https://github.com/xiph/opus | **BSD-3-Clause** | Permissive; compatible with GPL-3.0 and MIT. |
| **FFmpeg & SDL2** | Linked dynamically in Linux `nodedeck-stream` | https://ffmpeg.org / https://libsdl.org | **LGPL-2.1+ / zlib** | Dynamically linked system libraries on Linux. |
| **Sunshine (`nodedeck-host`)** | Optional bundled Linux/macOS host service | https://github.com/SunshineStream/Sunshine | **GPL-3.0** | Runs as an independent out-of-process service (`nodedeck-host.service`). |

## Distribution Guidance
- **Internal / personal use**: No extra redistribution steps required.
- **Public binary release**: Either distribute the combined macOS/Linux binaries under **GPL-3.0** with full corresponding source code, or isolate `CMoonlightCommon` into a standalone GPL-3.0 streaming helper process (already the architecture used on Linux via `nodedeck-stream`).
