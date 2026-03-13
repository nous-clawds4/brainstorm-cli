# Brainstorm-CLI

**Brainstorm-UI for humans. Brainstorm-CLI for agents.**

A command-line tool that enables LLM agents to interact with the [Brainstorm](https://github.com/nosfabrica/brainstorm_server) backend — the same server that powers the Brainstorm web UI, but designed for programmatic access by AI agents.

## What is Brainstorm?

Brainstorm is a personalized Web of Trust nostr relay built by [NosFabrica](https://nosfabrica.com). It features:

- **Decentralized Lists** (kinds 9998/9999/39998/39999) — the tapestry protocol for curating simple lists via your web of trust
- **GrapeRank** — contextual trust scoring ("PageRank for people")
- **Concept Graphs** — structured knowledge representation built from list relationships
- **Neo4j Knowledge Graph** — queryable graph database of all concepts, properties, and relationships

## Purpose

The Brainstorm web UI (`Brainstorm-UI`) is designed for human users — visual, interactive, browser-based.

This CLI is designed for **LLM agents** — structured, scriptable, and self-documenting. It provides:

- **CLI commands** to query and interact with the Brainstorm API (concepts, lists, graph queries, normalization, sync, etc.)
- **Agent documentation** (SKILL.md, BIBLE.md) that teaches agents everything they need to know about the Brainstorm data model, tapestry protocol, and available operations
- **Structured output** (JSON) suitable for agent consumption

## Status

🚧 **Under construction** — skeleton repo, commands and docs coming soon.

## License

[GNU Affero General Public License v3.0](LICENSE)
