# Brainstorm Bible

> **Audience:** AI agents and developers joining the Brainstorm project.
> Read this file to fully onboard — it covers what Brainstorm is, how it works, what's been built, and how to interact with it programmatically.

**Last updated:** 2026-03-14

---

## Table of Contents

1. [What Is Brainstorm?](#1-what-is-brainstorm)
2. [Vision and Why It Matters](#2-vision-and-why-it-matters)
3. [Repos](#3-repos)
4. [Architecture](#4-architecture)
5. [Data Flow](#5-data-flow)
6. [The Social Graph (Neo4j)](#6-the-social-graph-neo4j)
7. [GrapeRank Algorithm](#7-graperank-algorithm)
8. [Trusted Assertions](#8-trusted-assertions)
9. [Authentication](#9-authentication)
10. [API Reference](#10-api-reference)
11. [Infrastructure Services](#11-infrastructure-services)
12. [One-Click Deployment](#12-one-click-deployment)
13. [Configuration](#13-configuration)
14. [Brainstorm-CLI Commands](#14-brainstorm-cli-commands)
15. [Testing Strategy](#15-testing-strategy)
16. [What's Been Built](#16-whats-been-built)
17. [What's In Progress](#17-whats-in-progress)
18. [What's Yet To Be Built](#18-whats-yet-to-be-built)
19. [Key Design Decisions](#19-key-design-decisions)
20. [People](#20-people)
21. [Related Projects](#21-related-projects)
22. [Glossary](#22-glossary)

---

## 1. What Is Brainstorm?

Brainstorm is a **personalized Web of Trust engine** built on [nostr](https://nostr.com) and [Neo4j](https://neo4j.com). It ingests social signals from the nostr network (follows, mutes, reports), computes contextual trust scores using the **GrapeRank** algorithm, and publishes the results as **Trusted Assertions** back to nostr.

**The two interfaces:**

- **Brainstorm-UI** — Web application for humans to explore their social graph, view trust scores, and trigger GrapeRank calculations.
- **Brainstorm-CLI** (this repo) — Command-line tool for AI agents to interact with the Brainstorm backend programmatically.

**Core capabilities:**

- Ingest nostr social graph events (kind 3 follows, kind 10000 mutes, kind 1984 reports)
- Build and maintain a Neo4j social graph of `NostrUser` nodes and `FOLLOWS`/`MUTES`/`REPORTS` relationships
- Compute personalized trust scores via GrapeRank (influence, confidence, hops)
- Publish trust scores as kind 30382 Trusted Assertion events to nostr relays
- Provide per-user "observer" keypairs for publishing personalized trust data

---

## 2. Vision and Why It Matters

### The Problem

Nostr gives everyone a voice, but no way to know who to trust. Anyone can create an account. Spam, impersonation, and low-quality content are filtered only by individual follow lists — a blunt tool.

### The Solution

Brainstorm computes **personalized, contextual trust scores** for every nostr user, from the perspective of any given observer. It's "PageRank for people" — but personalized:

- **Alice's** trust scores are computed from Alice's perspective (her follows, her web of trust)
- **Bob's** trust scores are different — computed from Bob's graph
- No single authority decides who is trustworthy
- Scores propagate transitively: if Alice trusts Bob, and Bob trusts Carol, Carol gets some (diminished) trust from Alice's perspective

### GrapeRank in One Sentence

GrapeRank takes an observer's social graph (follows = positive signal, mutes/reports = negative signal), propagates trust through the network using iterative scoring rounds, and produces a scorecard for every reachable user with an `influence` score between 0 and 1.

### NosFabrica Context

Brainstorm is built by [NosFabrica](https://nosfabrica.com), a company focused on sovereign healthcare on nostr and Bitcoin. The immediate application is health data trust engines — computing trust scores for healthcare providers and health data. But the GrapeRank engine is general-purpose and can score trust in any context.

---

## 3. Repos

All repos are under the [NosFabrica GitHub organization](https://github.com/nosfabrica):

| Repo | Description | Language | Status |
|------|-------------|----------|--------|
| **[brainstorm_server](https://github.com/nosfabrica/brainstorm_server)** | FastAPI HTTP API — the main backend | Python | Active |
| **[Brainstorm-UI](https://github.com/nosfabrica/Brainstorm-UI)** | Web frontend (React/Vite) | TypeScript | Active |
| **[brainstorm_graperank_algorithm](https://github.com/nosfabrica/brainstorm_graperank_algorithm)** | GrapeRank scoring engine | Java | Active |
| **[neofry](https://github.com/nosfabrica/neofry)** | Custom strfry fork with Redis integration | C++ | Active |
| **[brainstorm_one_click_deployment](https://github.com/nosfabrica/brainstorm_one_click_deployment)** | Docker Compose for full stack | YAML | Active |

This repo (**brainstorm-cli**) lives at [nous-clawds4/brainstorm-cli](https://github.com/nous-clawds4/brainstorm-cli).

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    External Nostr Network                     │
│  (relay.damus.io, nos.lol, wot.grapevine.network, etc.)     │
└──────────────┬───────────────────────────────┬───────────────┘
               │ stream kinds 3,1984,10000     │ publish kind 30382
               ▼                               ▲
┌──────────────────────┐              ┌────────────────────┐
│       Neofry          │              │      strfry         │
│  (custom strfry fork) │              │  (vanilla relay)    │
│  port 7777            │              │  port 7778          │
│  streams from remote  │              │  stores Trusted     │
│  relays, pushes to    │              │  Assertion events   │
│  Redis on every write │              │                     │
└──────────┬────────────┘              └────────▲────────────┘
           │ RPUSH "strfry:events"              │ send_event()
           ▼                                    │
┌──────────────────────┐              ┌─────────┴──────────┐
│        Redis          │◄────────────│  Brainstorm Server  │
│   (message queues)    │─────────────►│  (FastAPI, port 8000)│
│                       │              │                     │
│  Queues:              │              │  Routes:            │
│  • strfry:events      │              │  • /brainstormPubkey │
│  • message_queue      │              │  • /brainstormRequest│
│  • results_queue      │              │  • /authChallenge    │
│  • nostr_results_queue│              │  • /user             │
│  • write_neo4j_queue  │              │                     │
│  • job_started_queue  │              │  Background tasks:  │
│                       │              │  • Event consumer    │
│                       │              │  • Result processor  │
│                       │              │  • Neo4j writer      │
│                       │              │  • Nostr uploader    │
└──────────┬────────────┘              └──────────┬──────────┘
           │                                      │
           │              ┌────────────────┐      │
           │              │     Neo4j       │◄─────┘
           │              │  (graph DB)     │
           │              │                 │
           │              │  NostrUser nodes│
           │              │  FOLLOWS edges  │
           │              │  MUTES edges    │
           │              │  REPORTS edges  │
           │              │  influence_*    │
           │              │  properties     │
           │              └────────┬───────┘
           │                       │
           │              ┌────────▼───────┐
           └──────────────►   GrapeRank     │
                          │  (Java engine)  │
                          │                 │
                          │  Reads graph    │
                          │  from Neo4j,    │
                          │  computes       │
                          │  scorecards,    │
                          │  returns via    │
                          │  Redis          │
                          └─────────────────┘

┌─────────────────────────┐
│      PostgreSQL          │
│  (port 5432)             │
│                          │
│  Tables:                 │
│  • brainstorm_request    │
│  • brainstorm_nsec       │
│  (auth, job tracking)    │
└──────────────────────────┘
```

### Service Summary

| Service | Port | Purpose |
|---------|------|---------|
| **Brainstorm Server** | 8000 | FastAPI HTTP API, event processing, job orchestration |
| **Neo4j** | 7474 (HTTP), 7687 (Bolt) | Social graph storage |
| **PostgreSQL** | 5432 | Auth data, job queue state, observer keypairs |
| **Redis** | 6379 | Message queues between all services |
| **Neofry** | 7777 | Nostr relay (inbound events → Redis) |
| **strfry** | 7778 | Nostr relay (outbound Trusted Assertions) |

---

## 5. Data Flow

### Inbound: Nostr Events → Social Graph

1. **Neofry** (custom strfry) connects to remote relays via its router config and streams down kind 3 (follows), kind 10000 (mutes), and kind 1984 (reports) events
2. On every accepted write, Neofry's C++ code calls `redis_rpush("strfry:events", event_json)` — pushing the raw nostr event JSON into a Redis list
3. **Brainstorm Server**'s `consume_strfry_plugin_messages()` background task pops events from Redis and calls `process_strfry_event()`:
   - **Kind 3** (Contact List): Creates/updates `NostrUser` nodes and `FOLLOWS` relationships. Replaces old follows (replaceable event semantics).
   - **Kind 10000** (Mute List): Creates/updates `MUTES` relationships. Replaces old mutes.
   - **Kind 1984** (Report): Creates `REPORTS` relationships. Additive (reports accumulate).
4. Result: Neo4j contains a live social graph of the nostr network

### Computation: GrapeRank Scoring

1. User (or API client) triggers a GrapeRank calculation via `POST /brainstormRequest/` or `POST /user/graperank`
2. Server creates a `BrainstormRequest` record in PostgreSQL and pushes it to the `message_queue` Redis list
3. **GrapeRank** (Java) picks up the job, reads the observer's social graph from Neo4j, and runs iterative trust propagation:
   - Follows = positive signal (trust)
   - Mutes/Reports = negative signal (distrust)
   - Trust propagates through hops with diminishing influence
   - Produces a `ScoreCard` for every reachable user
4. Results flow back through Redis to the server, which:
   - Writes influence scores to Neo4j (`influence_{observer}` properties on NostrUser nodes)
   - Publishes kind 30382 Trusted Assertion events to the strfry relay
   - Updates the PostgreSQL job record with status and results

### Outbound: Trusted Assertions → Nostr

For each scorecard with influence above the cutoff threshold:

```json
{
  "kind": 30382,
  "tags": [
    ["d", "<observee_pubkey>"],
    ["rank", "<influence * 100, rounded>"],
    ["followers", "<trusted_followers_count>"]
  ],
  "content": ""
}
```

These are signed with the **observer's Brainstorm keypair** (not the user's own nostr key) and published to the strfry relay.

---

## 6. The Social Graph (Neo4j)

### Node Type

| Label | Key Property | Description |
|-------|-------------|-------------|
| `NostrUser` | `pubkey` (hex, unique) | A nostr user |

### Relationship Types

| Type | Meaning | Source Event Kind |
|------|---------|-------------------|
| `FOLLOWS` | User A follows User B | Kind 3 (Contact List) |
| `MUTES` | User A mutes User B | Kind 10000 (Mute List) |
| `REPORTS` | User A reports User B | Kind 1984 (Report) |

### Dynamic Properties

After GrapeRank runs for an observer, each `NostrUser` node gets:

- `influence_{observer_pubkey}` — float, 0 to 1
- `hops_{observer_pubkey}` — integer, distance from observer

### Cypher Examples

```cypher
-- Who does a user follow?
MATCH (u:NostrUser {pubkey: $pubkey})-[:FOLLOWS]->(f:NostrUser)
RETURN f.pubkey

-- Who follows a user?
MATCH (f:NostrUser)-[:FOLLOWS]->(u:NostrUser {pubkey: $pubkey})
RETURN f.pubkey

-- Get influence scores from observer's perspective
MATCH (u:NostrUser)
WHERE u.influence_abc123def456 IS NOT NULL
RETURN u.pubkey, u.influence_abc123def456 AS influence
ORDER BY influence DESC
LIMIT 100
```

---

## 7. GrapeRank Algorithm

### Input

- An **observer pubkey** (whose perspective to compute from)
- The social graph in Neo4j (FOLLOWS, MUTES, REPORTS)

### Output

A set of **ScoreCards**, one per reachable user:

```json
{
  "observer": "hex_pubkey_of_observer",
  "observee": "hex_pubkey_of_scored_user",
  "context": "not a bot",
  "average_score": 0.85,
  "input": 0.5,
  "confidence": 0.92,
  "influence": 0.78,
  "verified": null,
  "hops": 2,
  "trusted_followers": 15
}
```

### Key Fields

| Field | Type | Meaning |
|-------|------|---------|
| `influence` | float 0-1 | The main trust score. Higher = more trusted from observer's perspective |
| `confidence` | float 0-1 | How confident the algorithm is in this score |
| `hops` | int | Graph distance from observer |
| `trusted_followers` | int | How many trusted users follow this person |
| `average_score` | float | Raw average of input signals |

### Confidence Buckets

The server categorizes scores by confidence for reporting:

| Bucket | Influence Threshold |
|--------|-------------------|
| High | ≥ 0.5 |
| Medium-High | ≥ 0.2 |
| Medium | ≥ 0.07 |
| Medium-Low | ≥ 0.02 |
| Low | < 0.02 |

### Cutoff

Scores below `cutoff_of_valid_graperank_scores` (default: 0.02) are not published as Trusted Assertions.

---

## 8. Trusted Assertions

Trusted Assertions are nostr events (kind 30382) that represent one user's trust evaluation of another, as computed by GrapeRank.

### Event Structure

```json
{
  "kind": 30382,
  "pubkey": "<observer_brainstorm_pubkey>",
  "tags": [
    ["d", "<observee_pubkey>"],
    ["rank", "78"],
    ["followers", "15"]
  ],
  "content": "",
  "created_at": 1710000000,
  "id": "...",
  "sig": "..."
}
```

### Important Details

- **Signed by the observer's Brainstorm keypair** — not the user's personal nostr key. Each user gets a unique keypair managed by Brainstorm (stored in PostgreSQL as an nsec).
- **Replaceable** — kind 30382 is a parameterized replaceable event (NIP-33). The `d` tag is the observee's pubkey, so each observer has exactly one Trusted Assertion per observee.
- **Published to strfry** (port 7778) — the vanilla strfry relay that serves as the output channel.
- **Rank is influence × 100, rounded** — e.g., influence 0.78 → rank 78.

---

## 9. Authentication

The Brainstorm API uses **nostr-based challenge-response authentication**:

### Flow

1. **Get challenge:** `GET /authChallenge/{pubkey}` → returns a random 32-char hex challenge
2. **Sign event:** Client creates a nostr event with:
   - Author = the authenticating pubkey
   - Tag `["t", "brainstorm_login"]`
   - Tag `["challenge", "<the_challenge_string>"]`
   - Valid signature
3. **Submit:** `POST /authChallenge/{pubkey}/verify` with `{ "signed_event": <the_event_json> }`
4. **Receive JWT:** Server verifies signature, challenge match, and returns a JWT token
5. **Use JWT:** Include `Authorization: Bearer <token>` header on authenticated endpoints (`/user/*`)

### Token Details

- Algorithm: HS256
- Expiry: configurable (default 60 minutes)
- Payload contains: `nostr_pubkey`, `expires_date`

---

## 10. API Reference

Base URL: `http://localhost:8000` (local dev) or your deployment URL.

### Health Check

```
GET /health
→ 1
```

No auth required. Returns `1` if server is running.

### Brainstorm Pubkey

```
GET /brainstormPubkey/{nostr_pubkey}
→ {
    "code": 200,
    "data": {
      "global_pubkey": "<the nostr pubkey>",
      "brainstorm_pubkey": "<the observer's brainstorm pubkey>",
      "triggered_graperank": { ... } | null,
      "created_at": "...",
      "updated_at": "..."
    }
  }
```

No auth required. Returns (or creates) the Brainstorm observer keypair for a given nostr pubkey. If the observer is new, automatically triggers a GrapeRank calculation.

### Brainstorm Request

**Create a request:**

```
POST /brainstormRequest/
Body: {
  "algorithm": "graperank",
  "parameters": "<observer_pubkey_hex>",
  "pubkey": "<observer_pubkey_hex>"
}
→ {
    "code": 200,
    "data": {
      "private_id": 42,
      "status": "WAITING",
      "ta_status": null,
      "internal_publication_status": null,
      "result": null,
      "count_values": null,
      "password": "<auto_generated_password>",
      "algorithm": "graperank",
      "parameters": "<pubkey>",
      "how_many_others_with_priority": 3,
      "pubkey": "<pubkey>",
      "created_at": "...",
      "updated_at": "..."
    }
  }
```

**Poll status:**

```
GET /brainstormRequest/{id}?brainstorm_request_password=<password>&include_result=true
→ {
    "code": 200,
    "data": {
      "private_id": 42,
      "status": "SUCCESS" | "WAITING" | "ONGOING" | "FAILURE",
      "ta_status": "SUCCESS" | "ONGOING" | null,
      "internal_publication_status": "SUCCESS" | "ONGOING" | null,
      "result": "<JSON string of GrapeRank result>" | null,
      "count_values": "<JSON string of confidence buckets>",
      ...
    }
  }
```

### Request Lifecycle

| Status | Meaning |
|--------|---------|
| `WAITING` | Queued, not yet picked up |
| `ONGOING` | GrapeRank is computing |
| `SUCCESS` | Computation complete |
| `FAILURE` | Computation failed |

Sub-statuses track downstream publishing:
- `ta_status` — Trusted Assertion publication to nostr relay
- `internal_publication_status` — Neo4j influence score writes

### Auth Challenge

```
GET /authChallenge/{pubkey}
→ { "code": 200, "data": { "challenge": "a1b2c3d4..." } }

POST /authChallenge/{pubkey}/verify
Body: { "signed_event": { <nostr_event_json> } }
→ { "code": 200, "data": { "token": "<jwt_token>" } }
```

### User (Auth Required)

All `/user` endpoints require `Authorization: Bearer <jwt_token>` header.

```
GET /user/self
→ {
    "code": 200,
    "data": {
      "graph": {
        "followed_by": [{"pubkey": "...", "influence": 0.85}, ...],
        "following": [...],
        "muted_by": [...],
        "muting": [...],
        "reported_by": [...],
        "reporting": [...],
        "influence": 0.95
      },
      "history": {
        "pubkey": "...",
        "ta_pubkey": "...",
        "last_time_calculated_graperank": "...",
        "last_time_triggered_graperank": "...",
        "created_at": "...",
        "updated_at": "..."
      }
    }
  }

GET /user/{pubkey}
→ { "code": 200, "data": { "followed_by": [...], ... , "influence": 0.72 } }

GET /user/graperankResult
→ { "code": 200, "data": { <latest BrainstormRequestInstance or null> } }

POST /user/graperank
→ { "code": 200, "data": { <new BrainstormRequestInstance> } }
```

The `influence` values in the graph response are from the **authenticated user's perspective** (their GrapeRank scores).

---

## 11. Infrastructure Services

### Neofry (Custom strfry)

A fork of [strfry](https://github.com/hoytech/strfry) with one critical modification: every accepted event write triggers a `redis_rpush("strfry:events", event_json)` call via embedded hiredis. This is the bridge from the nostr relay to the processing pipeline.

**Router config** streams down kinds 3, 1984, 10000 from `wss://wot.grapevine.network`.

### Redis

Acts as the message bus connecting all services:

| Queue | Producer | Consumer | Payload |
|-------|----------|----------|---------|
| `strfry:events` | Neofry | Server (event processor) | Raw nostr event JSON |
| `message_queue` | Server (API) | GrapeRank (Java) | BrainstormRequest JSON |
| `results_message_queue` | GrapeRank | Server (result processor) | GrapeRank results |
| `nostr_results_message_queue` | Server | Server (nostr uploader) | Results for TA publishing |
| `write_neo4j_message_queue` | Server | Server (neo4j writer) | Results for graph writes |
| `job_started_queue` | GrapeRank | Server (status updater) | Job started notification |

### GrapeRank (Java)

A standalone Java application (Maven project) that:
1. Listens on the `message_queue` Redis list
2. Reads the observer's social graph from Neo4j
3. Runs the iterative GrapeRank algorithm
4. Pushes results to `results_message_queue`, `nostr_results_message_queue`, and `write_neo4j_message_queue`

### PostgreSQL

Stores:
- **brainstorm_nsec** — Observer keypairs (pubkey → nsec mapping)
- **brainstorm_request** — Job queue records (status, result, timestamps)

### Neo4j

Stores the social graph. Accessed directly by both the Brainstorm Server and the GrapeRank engine. Key constraint: `NostrUser.pubkey` is unique.

---

## 12. One-Click Deployment

The `brainstorm_one_click_deployment` repo provides a single `docker-compose.yml` that runs all 6 services:

### Prerequisites

1. Build the server image: `cd brainstorm_server && docker build -t brainstorm-server-service .`
2. Build the GrapeRank image: `cd brainstorm_graperank_algorithm && docker build -t brainstorm-graperank-service .`

### Run

```bash
cd brainstorm_one_click_deployment
docker compose up -d
```

### Default Ports

| Service | Port |
|---------|------|
| Brainstorm Server API | 8000 |
| Neo4j Browser | 7474 |
| Neo4j Bolt | 7688 |
| Neofry (inbound relay) | 7777 |
| strfry (outbound relay) | 7778 |
| PostgreSQL | 5432 |
| Redis | 6379 |

### Initial Sync

If `perform_nostr_full_sync=true`, the server will populate the local relay from `wss://wot.grapevine.network` on first startup. This can take a while for large networks. Set to `false` to skip.

---

## 13. Configuration

### Server Environment Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `DB_URL` | `postgresql+asyncpg://postgres:postgrespw@postgres:5432/brainstorm-database` | PostgreSQL connection |
| `DEPLOY_ENVIRONMENT` | `LOCAL` or `DEV` | Enables docs UI when LOCAL |
| `AUTH_ALGORITHM` | `HS256` | JWT signing algorithm |
| `AUTH_SECRET_KEY` | `supersecretkey` | JWT signing secret |
| `AUTH_ACCESS_TOKEN_EXPIRE_MINUTES` | `60` | JWT token lifetime |
| `NEO4J_DB_URL` | `neo4j://localhost:7687` | Neo4j Bolt connection |
| `NEO4J_DB_USERNAME` | `neo4j` | Neo4j user |
| `NEO4J_DB_PASSWORD` | `password` | Neo4j password |
| `REDIS_HOST` | `redis_strfry` | Redis hostname |
| `REDIS_PORT` | `6379` | Redis port |
| `NOSTR_TRANSFER_FROM_RELAY` | `wss://wot.grapevine.network` | Source relay for initial sync |
| `NOSTR_TRANSFER_TO_RELAY` | `ws://neofry:7777` | Local relay to sync into |
| `NOSTR_UPLOAD_TA_EVENTS_RELAY` | `ws://strfry:7777` | Relay for publishing TAs |
| `CUTOFF_OF_VALID_GRAPERANK_SCORES` | `0.02` | Minimum influence for TA publishing |
| `PERFORM_NOSTR_FULL_SYNC` | `true` | Whether to do initial full relay sync |

---

## 14. Brainstorm-CLI Commands

> **Status: Planned** — These commands are the target for this repo.

```bash
# Connectivity
brainstorm health                              # Check if server is reachable

# Authentication
brainstorm auth <pubkey>                       # Nostr challenge-response → JWT
brainstorm auth status                         # Check current token validity

# Observer Management
brainstorm pubkey <nostr_pubkey>               # Get/create Brainstorm observer keypair

# Computation Requests
brainstorm request create <algo> <params> <pk> # Submit a computation request
brainstorm request status <id> <password>      # Poll request status
brainstorm request result <id> <password>      # Get full result (include_result=true)

# User Graph (auth required)
brainstorm user self                           # Own social graph + history
brainstorm user <pubkey>                       # Another user's graph
brainstorm user graperank                      # Latest GrapeRank result
brainstorm user graperank trigger              # Trigger new GrapeRank calculation

# Testing
brainstorm test smoke                          # Basic connectivity checks
brainstorm test auth                           # Authentication flow test
brainstorm test graperank                      # Full GrapeRank pipeline test
brainstorm test all                            # Run all tests
```

### Output Format

All commands output JSON by default for agent consumption. Add `--pretty` for human-readable formatting.

### Configuration

```bash
brainstorm config set server-url http://localhost:8000
brainstorm config set token <jwt_token>
brainstorm config show
```

Config stored in `~/.brainstorm-cli/config.json`.

---

## 15. Testing Strategy

### Smoke Tests

1. **Server reachable** — `GET /health` returns 1
2. **Neo4j reachable** — Server can query Neo4j (implicit in other tests)
3. **Redis reachable** — Server can queue jobs (implicit in request creation)

### Authentication Tests

1. **Challenge generation** — `GET /authChallenge/{pubkey}` returns a challenge string
2. **Challenge verification** — Signed event with correct tags → JWT token
3. **Token usage** — JWT works on `/user/self`
4. **Token rejection** — Invalid/expired tokens are rejected

### Observer Tests

1. **New observer creation** — New pubkey gets a brainstorm_pubkey + triggers GrapeRank
2. **Existing observer retrieval** — Known pubkey returns existing data
3. **GrapeRank auto-trigger** — New observer has a non-null `triggered_graperank`

### GrapeRank Pipeline Tests

1. **Request creation** — Returns WAITING status with password
2. **Queue processing** — Status transitions: WAITING → ONGOING → SUCCESS
3. **Result validity** — Scorecards have valid influence values (0-1)
4. **Neo4j write** — influence_{observer} properties appear on NostrUser nodes
5. **TA publication** — kind 30382 events appear on strfry relay

### Graph Integrity Tests

1. **FOLLOWS consistency** — Follows match kind 3 event tags
2. **MUTES replacement** — New mute list replaces old (not additive)
3. **REPORTS accumulation** — Reports are additive
4. **Influence symmetry** — influence scores exist for computed observers

### End-to-End Test

Full user journey: Auth → trigger GrapeRank → poll until complete → verify scores → check TAs on relay.

---

## 16. What's Been Built

- ✅ Full server API (FastAPI) with all 4 route groups
- ✅ Neo4j social graph ingestion (kinds 3, 10000, 1984)
- ✅ GrapeRank algorithm (Java) with iterative trust propagation
- ✅ Trusted Assertions publishing (kind 30382)
- ✅ Nostr challenge-response authentication
- ✅ Redis message queue pipeline (6 queues)
- ✅ Neofry: custom strfry with Redis integration
- ✅ Docker Compose one-click deployment
- ✅ Web UI (Brainstorm-UI) with profile explorer

---

## 17. What's In Progress

- 🔧 Brainstorm-CLI (this repo) — agent-facing CLI tool
- 🔧 Brainstorm-UI refinements — deeper integration with server API
- 🔧 Production deployment hardening

---

## 18. What's Yet To Be Built

- 📋 Additional GrapeRank contexts (currently only "not a bot")
- 📋 Zap-based trust signals (kind 9735)
- 📋 DList integration (kinds 9998/9999/39998/39999) for curated list trust
- 📋 LNURL/Lightning payment integration
- 📋 Multi-relay Trusted Assertion distribution
- 📋 Historical score tracking and trends
- 📋 Rate limiting and abuse prevention for GrapeRank triggers

---

## 19. Key Design Decisions

### Per-User Observer Keypairs

Each user gets a **separate Brainstorm-managed keypair** for publishing Trusted Assertions. This means:
- TAs are clearly identified as Brainstorm-generated (not user-authored)
- Users don't need to share their nsec with the server
- Each observer's trust evaluations are signed by a distinct key

### Redis as Message Bus

All inter-service communication goes through Redis lists (RPUSH/BLPOP pattern). This decouples services and allows independent scaling/restarting.

### Replaceable Event Semantics

- Kind 3 (follows) and kind 10000 (mutes) are **replaceable**: new events completely replace old relationship sets in Neo4j
- Kind 1984 (reports) are **additive**: reports accumulate, never removed
- Kind 30382 (TAs) are **parameterized replaceable** (NIP-33): one TA per observer+observee pair

### Influence Threshold

Only scores above `cutoff_of_valid_graperank_scores` (default 0.02) get published as TAs. This prevents noise from low-confidence scores flooding the relay.

---

## 20. People

| Person | Role | Focus |
|--------|------|-------|
| **Dave (wds4)** | CoFounder, NosFabrica | Tapestry protocol, concept graphs, Web of Trust theory |
| **Avi Burra** | CoFounder, NosFabrica | Product management, PlebChain Radio, healthcare applications |
| **Jon Gordon** | CoFounder, NosFabrica | |
| **Vitor** | CoFounder, NosFabrica | NIP-82, medical data on nostr |
| **Matthias DeBernardini** | Contributor | agentic-wot, dcosl-core, Rust tooling |

---

## 21. Related Projects

| Project | Relationship |
|---------|-------------|
| **[Tapestry](https://github.com/nous-clawds4/tapestry)** | Sister project — decentralized knowledge graphs on nostr. Uses GrapeRank for "loose consensus" on concept definitions. |
| **[tapestry-cli](https://github.com/nous-clawds4/tapestry-cli)** | CLI for Tapestry concept graph operations |
| **[agentic-wot](https://github.com/PrettyGoodFreedomTech/agentic-wot)** | Matthias's project — AI agent that pays bounties using WoT scores. Includes `dcosl-core` Rust crate. |
| **[GrapeRank (concept)](https://github.com/wds4/DCoSL)** | Dave's original DCoSL protocol specification |

---

## 22. Glossary

| Term | Definition |
|------|-----------|
| **Brainstorm** | The full system: relay ingestion + graph + GrapeRank + Trusted Assertions |
| **GrapeRank** | Trust scoring algorithm — "PageRank for people" with personalized, contextual scores |
| **Trusted Assertion (TA)** | A kind 30382 nostr event publishing one user's trust evaluation of another |
| **Observer** | The user whose perspective GrapeRank computes from |
| **Observee** | The user being scored |
| **Influence** | The main GrapeRank output score (0-1). Higher = more trusted from observer's perspective |
| **ScoreCard** | A single trust evaluation: observer → observee with influence, confidence, hops |
| **Brainstorm Pubkey** | A server-managed nostr keypair assigned to each observer for signing TAs |
| **Neofry** | Custom strfry fork that pushes every accepted event to Redis |
| **strfry** | High-performance nostr relay (C++). Used vanilla for TA output, custom (Neofry) for input |
| **Kind 3** | Nostr Contact List — who a user follows |
| **Kind 10000** | Nostr Mute List — who a user mutes |
| **Kind 1984** | Nostr Report — user reports another user |
| **Kind 30382** | Trusted Assertion — parameterized replaceable event for trust scores |
| **NIP-33** | Nostr protocol spec for parameterized replaceable events (d-tag based) |
| **NosFabrica** | The company building Brainstorm — sovereign healthcare on nostr + Bitcoin |
| **DCoSL** | Decentralized Curation of Simple Lists — the protocol underlying Tapestry |
| **Loose Consensus** | When overlapping webs of trust converge on shared data without central coordination |
