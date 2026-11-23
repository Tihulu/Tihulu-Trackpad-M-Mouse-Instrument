# Applying the Studio overlay

The overlay is designed to be copied into a fork of `os6/nospeaker` without replacing the original CLI source.

Expected fork layout after applying it:

```text
nospeaker/
├── nospeaker.swift          # original upstream file remains
├── build.sh                 # original upstream file remains
├── play.sh                  # original upstream file remains
├── README.md                # original upstream README remains
├── LICENSE                  # original upstream license remains
├── STUDIO.md                # downstream entry point
├── studio/                  # NoSpeaker Studio project
└── .github/workflows/
    └── nospeaker-studio.yml
```

Recommended development branch: `studio/v0.1-foundation`.
