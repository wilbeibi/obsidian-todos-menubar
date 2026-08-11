#!/usr/bin/env bash
# Seed a synthetic Obsidian vault for recording the README demo.
# Dates are generated relative to today, so re-recording any day
# reproduces the same menu: 2 overdue, 2 today, 2 this week, 1 later.
set -euo pipefail

VAULT="${1:-/tmp/obsidian-todos-demo-vault}"

d() { date -v"$1"d +%Y-%m-%d; }

rm -rf "$VAULT"
mkdir -p "$VAULT"

cat > "$VAULT/Product Launch.md" <<EOF
# Product Launch

- [ ] Send beta invites to the waitlist ⏫ 📅 $(d -1)
- [ ] Review App Store screenshots 📅 $(d +0)
- [/] Draft release notes 📅 $(d +0)
- [x] Ship pricing page ✅ $(d -1)
EOF

cat > "$VAULT/Personal.md" <<EOF
# Personal

- [ ] Renew passport 🔺 📅 $(d -3)
- [ ] Book dentist appointment 📅 $(d +2)
- [ ] Research standing desks 🔽 due:: [[$(d +9)]]
EOF

cat > "$VAULT/Reading.md" <<EOF
# Reading

- [ ] Finish "The Design of Everyday Things" 📅 $(d +4)
- [x] Read the Hammerspoon docs ✅ $(d -2)
EOF

echo "Seeded demo vault at $VAULT"
