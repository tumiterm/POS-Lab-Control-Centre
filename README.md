# POS Lab Control Centre

One place to answer: **which POS lab can I safely use right now, and is it ready for my test?**
It shows who is on each lab, what component versions are installed (and whether they're a
"partly right" mix), MDD health, Windows service state, reservations and test readiness, all
before you open an RDP session.

## Status

Phase 0: discovery and design.

- [docs/requirements.md](docs/requirements.md): refined requirements and phases
- [docs/architecture.md](docs/architecture.md): proposed architecture and decisions
- [docs/open-questions.md](docs/open-questions.md): what we know and what we still need
- [discovery/](discovery/): read-only PowerShell script to run on a lab
