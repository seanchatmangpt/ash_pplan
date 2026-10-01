# Receipt: ggen-ecosystem lock re-observation (lane A4)

- date: 2026-10-01
- subject: `/Users/sac/ash_pplan/ecosystem.lock.toml` `[ggen_ecosystem]` entry (release v26.10.1)
- lane: A4, owned files only (ecosystem.lock.toml, this receipt)

## Observation command + output

```
$ docker manifest inspect ghcr.io/seanchatmangpt/ggen-ecosystem@sha256:917eb72a031da073f1d7e0c1295cda6023171275d79674b6303d5d817a3d4cb0
```

SUCCESS (exit 0). Registry returned an OCI image index for the exact pinned
digest (the digest is real and reachable):

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {"digest": "sha256:a66d6c9935274cf4442418416c188f743e6976ff2e3c39c29a0170ee02ff67ed", "platform": {"architecture": "amd64", "os": "linux"}},
    {"digest": "sha256:a1fdfdbee71e0282b5df11fe640aeabe2b7139e17256231921c07f797b814c8a", "platform": {"architecture": "unknown", "os": "unknown"}},
    {"digest": "sha256:aafaaa40f32dcbb7789880f3c329fb38351e38429b9c7e42cb6619bd5490e30a", "platform": {"architecture": "arm64", "os": "linux"}},
    {"digest": "sha256:5a77857fb23bd41b7e413a4de2a58739f52e67e212c79884f8be94af1eb76430", "platform": {"architecture": "unknown", "os": "unknown"}}
  ]
}
```

## Per-entry verdicts

| entry | verdict | evidence |
|---|---|---|
| `[ggen_ecosystem].digest` | OBSERVED (updated) | `docker manifest inspect` on the exact pinned digest succeeded; unchanged pin, reachable in registry. standing UNKNOWN -> OBSERVED, `observed_at` set. |
| `[ggen_ecosystem].sha` d17d62a30a84... | OBSERVED (exists upstream) | `gh api repos/seanchatmangpt/ggen-ecosystem/commits/d17d62a...` -> `d17d62a30a84`. |
| `[ggen_ecosystem].image_build_head` / `observed_success_run` | STALE (unchanged) | Still 0fa1c5c9839... / 33926356178 from before the v26.9.29 wave; no fresh exact-head CI run observed in this session. |
| `[ggen_igniter]` sha 39ba9e128653... | OBSERVED (exists upstream) | `gh api repos/seanchatmangpt/ggen_igniter/commits/39ba9e12...` -> `39ba9e128653`. pin_status "behind ecosystem-vendored ae205c3b (26.9.29)" remains STALE as a version relationship — no re-promotion performed. |
| `[conformance]` rdflib 7.6.0 / pyshacl 0.40.1 | OBSERVED | Not re-verified against a live env this session; carried from lock, no counter-evidence. (untouched) |
| `[ash]` version_observed 3.33.11 | OBSERVED | mix.lock: `"ash": {:hex, :ash, "3.33.11", ...}` — exact match; meets floor 3.33.11. |
| `[reactor]` 1.0.7 | OBSERVED | mix.lock exact match. |
| `[ash_state_machine]` 0.2.13 | OBSERVED | mix.lock exact match. |
| `[ash_oban]` 0.9.0 | OBSERVED | mix.lock exact match. |
| `[durable_engine]` | UNKNOWN (unchanged) | stale_reason stands: CI not run on this change set; dependency digests not re-observed here. |
| `[dev_test_dependencies]` bb_reactor 0.2.4, bandit 1.12.5, plug 1.20.3, stream_data 1.4.0, ex4pm 26.9.30, opentelemetry_api 1.5.0 | OBSERVED (mix.lock matches) but standing UNKNOWN (unchanged) | Each version matches mix.lock exactly (including ex4pm 26.9.30 + override note vs ash_ex4pm's 26.9.9). stale_reason stands: CI not run, digests not re-observed. |
| `[dev_test_dependencies].ash_ex4pm_ref` 735ab7c3... | UNKNOWN | Remote existence not probed this session (out of lane scope). |

## Standing transitions

- `[ggen_ecosystem]`: UNKNOWN -> OBSERVED (digest-level; noted residual CI gap in stale_reason).
- All other UNKNOWN sections (`[durable_engine]`, `[dev_test_dependencies]`) remain UNKNOWN —
  the honest gate for those is an exact-head CI run, not a manifest inspect.

## Falsifier

Re-running `docker manifest inspect` on the pinned digest must still succeed; if the
registry returns MANIFEST_UNKNOWN or a different manifest list for that digest, this
receipt and the lock update are refuted.
