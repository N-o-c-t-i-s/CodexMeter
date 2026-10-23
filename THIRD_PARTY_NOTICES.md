# Third-Party Notices

CodexMeter is distributed under the MIT License. See [LICENSE](LICENSE).

## Usage Window Starter

The usage-window auto-start feature is behaviourally derived from **Usage Window
Starter** version 0.4.0:

- Upstream project: <https://github.com/foksa/usage-window-starter>
- Reference files: `src/go/core/codex.go`, `src/go/core/scheduler.go`,
  `src/go/core/exec.go`
- License: MIT
- Copyright (c) 2026 Djordje Radakovic

The derived elements are mechanisms rather than copied source: the 45-second
tolerance that distinguishes a hypothetical idle window from a running one, the
"send once, wait, then re-read to confirm" sequence, the reset-time plus grace
recheck, and the 30-minute minimum spacing between sends. The implementation in
this repository is native Swift written against Codex App Server and shares no
upstream source files.

The upstream license text follows.

```text
MIT License

Copyright (c) 2026 Djordje Radakovic

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Sparkle

In-app updates use [Sparkle](https://sparkle-project.org/), which remains under
its own license and is embedded as a framework.
