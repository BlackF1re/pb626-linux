#!/bin/sh
set -eu
kit=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sudo pwsh -NoProfile -File "$kit/PB626.ps1" "$@"
