#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${EMACS:-emacs}" --batch -Q -l "$root/Tools/check-doom-tangle.el"
