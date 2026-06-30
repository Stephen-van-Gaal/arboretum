#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# model-families.sh — single source mapping a model *family* to a concrete id.
#
# Sourced, never executed. This is the ONE place concrete model ids live for
# model routing; on a model release, edit the case arms here and nowhere else
# (a contract test enforces single-sourcing). Family names reuse the cost-tier
# vocabulary and still glob-match token-rates.sh (*haiku*/*sonnet*/*opus*), so
# accounting needs no change.
#
# Concrete ids verified 2026-06-28 (claude-api Appendix). Re-verify on change.

resolve_model_family() {
  case "${1:-}" in
    cheap)    echo "claude-haiku-4-5" ;;
    capable)  echo "claude-sonnet-4-6" ;;
    frontier) echo "claude-opus-4-8" ;;
    *)
      echo "model-families: unknown family '${1:-}' (want cheap|capable|frontier)" >&2
      return 1
      ;;
  esac
}
