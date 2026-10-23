# Usage Window Starter reference maintenance

CodexMeter implements this behavior in native Swift. Usage Window Starter is an
MIT-licensed design reference, not an embedded executable or runtime dependency.
The initial reference is [`v0.4.0`](https://github.com/foksa/usage-window-starter/tree/v0.4.0),
peeled commit `b346bb0b2d3bff478ae01ce8d01145455f5c917d`.
`UsageWindowStarter.lock.json` records the repository, explicit tag, commit,
complete reference inventory, SHA-256 values, native adaptation revision, and
review date. `LICENSE.UsageWindowStarter` preserves the original MIT notice.

| Upstream reference | Native adaptation |
| --- | --- |
| `src/go/core/codex.go`, `limits_test.go`, Codex fixture | `UsageWindowObservation`, `UsageWindowStartPolicy`, observation/policy tests |
| `scheduler.go`, scheduler/lifecycle tests | `UsageWindowStartSchedule`, `UsageWindowStartService`, schedule/recovery tests |
| `state.go`, `store.go`, `config.go`, store tests | `UsageWindowStartState`, settings/store/reserver/transitions, atomicity tests |
| `exec.go`, `instance.go`, related tests | `CodexWindowStartRunner`, turn bridge/bookkeeper/failure router, integration tests |

The inventory deliberately covers **every file under `src/go/core/`**, including
new files, deleted files, shared helpers, and tests. Changes outside this scope
still require a maintainer's release review. CodexMeter uses its existing
authenticated App Server and existing 10-second foreground/60-second background refresh rather than copying upstream's
execution or polling mechanisms. Pulling a tag therefore does not automatically
change Swift behavior. App users receive compiled updates through the ordinary
CodexMeter release process.

## Commands

Run from the CodexMeter repository root with Python 3 and Git. No Go, Bun,
upstream scripts, or upstream binaries are executed. The default isolated bare
Git cache is `~/Library/Caches/CodexMeter/UWSUpstream/repository.git`; it is never
the application repository. A custom `--cache-dir` must also be outside it.

First populate the cache and inspect the current baseline. `prepare` always
requires an explicit tag and a new output directory, including for this initial
zero-change comparison:

```sh
python3 -B Scripts/uws_upstream.py prepare \
  --tag v0.4.0 --output-dir /tmp/uws-v0.4.0-review
python3 -B Scripts/uws_upstream.py verify
python3 -B -m unittest discover -s Scripts/tests -p 'test_uws_upstream.py' -v
```

For the next upstream release, replace `vX.Y.Z` with its actual tag:

```sh
python3 -B Scripts/uws_upstream.py prepare \
  --tag vX.Y.Z --output-dir /tmp/uws-vX.Y.Z-review
```

Read `review.md`, compare upstream release notes and any relevant changes outside
`src/go/core/`, adapt the Swift implementation, and add or adjust meaningful
Swift regression tests. Review any license change. The candidate and report
contain reciprocal content hashes and the current baseline lock hash;
preparation leaves the accepted lock and app source untouched.

Only after that review and implementation, accept the candidate with a **new**
native revision and a concrete description of what was reviewed:

```sh
python3 -B Scripts/uws_upstream.py accept \
  --candidate /tmp/uws-vX.Y.Z-review/candidate.json \
  --adaptation-revision native-app-server-v2 \
  --review-note 'Reviewed parser and scheduler changes; adapted Swift behavior and regression coverage.'
python3 -B Scripts/uws_upstream.py verify
git diff -- Upstream/
```

Acceptance re-fetches both tags, checks the old and new inventories against Git
objects, rejects moved tags, stale candidates, and modified review files, then
runs **`swift test` itself** in this repository. A failed test or a success exit
without a passing nonempty suite cannot update the lock. Full test output stays
in the external cache; its SHA-256, command, completion time, and successful exit
are recorded in the accepted lock. The lock is replaced atomically only after
verification. The review note is a maintainer attestation: the tool cannot prove
that a person has correctly ported every upstream behavior.

`verify` is entirely offline and checks cached commit blobs, the complete locked
inventory, and the preserved MIT notice. It cannot check whether a remote tag
has moved; the explicit online `prepare`/`accept` commands perform that check.
Neither command commits, pushes, publishes, modifies Swift files, or changes
running application settings. No update runs at application startup.
