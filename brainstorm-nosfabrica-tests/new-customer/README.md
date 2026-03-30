# New Brainstorm Customer Test

End-to-end test of the Brainstorm onboarding pipeline: from fresh nostr
identity to personalized Trusted Assertions.

## What It Tests

Can a brand-new nostr user sign up with Brainstorm and receive their
personalized Web of Trust scores (kind 30382 Trusted Assertions)?

## Pipeline Under Test

```
1. New identity (kind:0, kind:3)
   └→ publish to public relays (primal, damus, nos.lol, purplepag.es)

2. Register with Brainstorm staging
   └→ GET /brainstormPubkey/<pubkey>  →  creates observer + auto-triggers GrapeRank

3. Fetch NIP-85 setup data
   └→ GET /setup/<pubkey>  →  returns [["30382:rank", <ta_pubkey>, <relay>], ...]

4. Publish kind 10040 (WoT Service Provider config)
   └→ signed by customer, published to public relays

5. GrapeRank computation (server-side)
   └→ reads social graph from Neo4j
   └→ propagates trust scores iteratively
   └→ publishes kind 30382 Trusted Assertions to the TA relay

6. Monitor TA relay for results
   └→ query kind 30382 from TA pubkey every 60s
   └→ stop when count stabilizes or 60 min elapsed
```

## Expected Behavior

| Phase | Expected Timing |
|-------|----------------|
| First TAs appear | ~10 minutes after signup |
| TAs stabilize | ~15–20 minutes after signup |
| Final TA count | ~100,000 events |

## What Each Run Does

1. **Generates a fresh keypair** — new identity every run
2. **Publishes kind:0** profile ("Brainstorm Test Customer #N")
3. **Publishes kind:3** following 5 random popular accounts
4. **Registers** with `brainstormserver-staging.nosfabrica.com`
5. **Fetches NIP-85 setup data** (TA pubkey, relay, descriptors)
6. **Signs and publishes kind 10040** event
7. **Monitors** the TA relay every 60s for kind 30382 events

## Verdicts

| Verdict | Meaning |
|---------|---------|
| `kind_10040_published: PASS` | Kind 10040 event was published successfully |
| `trusted_assertions_appeared: PASS` | At least one kind 30382 event appeared |
| `trusted_assertions_stabilized: PASS` | TA count stopped increasing (pipeline complete) |

## Usage

```bash
cd brainstorm-nosfabrica-tests/new-customer
./run-test.sh
```

No setup or reset needed — each run creates a fresh identity.

## Files

| File | Description |
|------|-------------|
| `run-test.sh` | Main test script |
| `state.json` | Run counter (tracks test number for key naming) |
| `results/` | JSON results per run |
| `README.md` | This file |

## Key Storage

Each test account's nsec is stored in `~/.config/nosfabrica-tests/keys.env`
as `NEW_CUSTOMER_<N>_NSEC`. These are test accounts with no real value, but
stored for reproducibility.

## Prerequisites

- `nak` CLI (v0.18+)
- `jq`, `curl`
