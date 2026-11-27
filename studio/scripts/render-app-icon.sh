# POSIX helper. Source this file; render only into the requested output path.
render_app_icon() (
    [ "$#" -eq 2 ] || exit 1
    source_svg=$1
    output_icns=$2
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/tihulu-icon.XXXXXX") || exit 1
    trap 'rm -rf "$scratch"' EXIT
    trap 'exit 1' HUP INT TERM
    iconset="$scratch/TihuluInstrument.iconset"
    mkdir "$iconset" || exit 1
    rsvg-convert --width 1024 --height 1024 "$source_svg" > "$iconset/icon_512x512@2x.png" || exit 1
    for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512"; do
        set -- $spec
        sips --resampleHeightWidth "$1" "$1" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_$2.png" >/dev/null || exit 1
    done
    iconutil -c icns "$iconset" -o "$output_icns" || exit 1
    [ -s "$output_icns" ] || exit 1
)
