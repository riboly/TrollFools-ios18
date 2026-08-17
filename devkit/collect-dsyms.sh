#!/bin/bash

set -euo pipefail

SOURCE_ROOT=${1:-.theos/obj}
OUTPUT_ROOT=${2:-.}

mkdir -p "$OUTPUT_ROOT"

while IFS= read -r -d '' bundle; do
  bundle_name=${bundle##*/}
  destination="$OUTPUT_ROOT/$bundle_name"
  if [ ! -e "$destination" ]; then
    cp -R "$bundle" "$destination"
    continue
  fi

  while IFS= read -r -d '' dwarf; do
    dwarf_name=${dwarf##*/}
    destination_dwarf="$destination/Contents/Resources/DWARF/$dwarf_name"
    if [ ! -e "$destination_dwarf" ]; then
      mkdir -p "${destination_dwarf%/*}"
      cp -p "$dwarf" "$destination_dwarf"
      continue
    fi

    existing_arches=" $(lipo -archs "$destination_dwarf") "
    incoming_arches=$(lipo -archs "$dwarf")
    should_merge=0
    has_duplicate=0
    for arch in $incoming_arches; do
      if [[ "$existing_arches" == *" $arch "* ]]; then
        has_duplicate=1
      else
        should_merge=1
      fi
    done

    if [ "$should_merge" -eq 1 ] && [ "$has_duplicate" -eq 1 ]; then
      echo "Cannot safely merge overlapping dSYM architectures: $destination_dwarf and $dwarf" >&2
      exit 1
    fi
    if [ "$should_merge" -eq 1 ]; then
      temporary=$(mktemp)
      if lipo -create "$destination_dwarf" "$dwarf" -output "$temporary"; then
        mv -f "$temporary" "$destination_dwarf"
      else
        rm -f "$temporary"
        exit 1
      fi
    fi
  done < <(find "$bundle/Contents/Resources/DWARF" -maxdepth 1 -type f -print0)
done < <(find "$SOURCE_ROOT" -name '*.dSYM' -type d -print0)

find "$OUTPUT_ROOT" -maxdepth 1 -name '*.dSYM' -type d -print
