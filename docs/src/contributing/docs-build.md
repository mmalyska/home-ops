# Documentation Build Supply Chain

This documentation build uses `uv` for strict, hashed dependency management.

## Setup

To work on documentation, use:
```bash
cd .github/mkdocs
# Local install for IDE support (ensure python 3.13 is available via mise)
uv venv
uv pip install -r requirements.txt
```

## Workflows

The build is automated in GitHub Actions, pinned by SHAs to ensure immutability.
