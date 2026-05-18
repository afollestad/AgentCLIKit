#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
hooks_dir="$repo_root/.git/hooks"
pre_commit="$hooks_dir/pre-commit"

mkdir -p "$hooks_dir"

cat > "$pre_commit" <<'HOOK'
#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

./scripts/lint.sh
git diff --check
HOOK

chmod +x "$pre_commit"

echo "Installed git pre-commit hook."
