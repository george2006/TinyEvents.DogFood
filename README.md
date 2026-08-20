# TinyEvents Dogfood

Private process-level hardening laboratory for TinyEvents.

This repository intentionally lives beside the public `TinyEvents` repository while the beta contract is being hardened:

```text
repos/
  TinyEvents/
  TinyEvents.Dogfood/
```

Until a hardened package is published, dogfood projects reference the sibling TinyEvents source projects directly. Release acceptance will later consume locally packed NuGet artifacts instead.

- [Beta hardening plan](docs/beta-hardening-lab.md)
- [Identity scenarios](identity/README.md)
- [Operational baseline](operations/README.md)
