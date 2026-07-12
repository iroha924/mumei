#!/usr/bin/env bash
# Verify every dependency lock a workflow installs from actually exists in the repo.
#
# review-reusable.yml branches on whether the semgrep lock is present: absent means
# an adopter has not vendored it, so semgrep is skipped and reported as `unknown`
# rather than as zero findings. That is right for adopters and wrong here — in THIS
# repository an absent lock does not mean "not vendored", it means a path was
# mistyped, and the mistyped path takes the same soft arm: the detector is silently
# skipped and CI stays green (#197). The `-r <path>` install sites fail loudly (pip
# exits 1 on a missing file); the lock-existence check does not. This lint closes
# that gap at commit time, before the typo can reach CI.
#
# The failure it guards against is not hypothetical: #194 moved the locks out of
# `.github/` (Dependabot refuses to write there, #191) and rewrote four lock paths
# by hand.
#
# A lock is a file a workflow INSTALLS FROM, so that is what the matcher looks for,
# and it looks two ways at once. By syntax: the argument of `-r` / `--requirement`,
# and the right-hand side of a `*lock=` assignment — this sees the path whatever the
# file is called, so renaming `requirements.txt` cannot hide it. By name: any
# `<dir>/requirements.txt` token — this sees the path whatever syntax installs it.
# The union is checked. Going blind now takes a new spelling AND a new name at once,
# where either alone was once enough.
#
# There is deliberately NO check that every tracked file under .github-deps/ is
# referenced. That was the earlier design and it was a mistake: to ask whether a file
# is an unreferenced lock, you must first decide whether it is a lock at all, and
# every way of deciding that is a list. A denylist of non-locks (README, .gitignore,
# the next thing) is always one entry short, and each miss is a false failure. An
# allowlist of lock names hides a renamed lock in silence, which is worse. Keying the
# matcher on how a lock is USED rather than what it is CALLED removes the question.
#
# set -u, no set -e (explicit handling).
set -u

# Resolve the root of the repository we are STANDING IN, not the one this script was
# copied from. Deriving it from ${BASH_SOURCE[0]} would pin the lint to the mumei
# checkout it lives in, and a lint whose failure path cannot be exercised against a
# fixture is exactly the untested fail-closed branch #197 is about.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$repo_root" ]]; then
  echo "lint-workflow-lock-paths: not a git repository" >&2
  exit 1
fi
cd "$repo_root" || {
  echo "lint-workflow-lock-paths: cannot cd to ${repo_root}" >&2
  exit 1
}

# Both extensions: GitHub Actions honours .yml AND .yaml, so scanning only .yml would
# let a lock reference in a .yaml workflow escape unchecked — and because the .yml
# files keep the match set non-empty, the gone-blind guard below would not fire
# either. `find` rather than a glob: an unmatched `*.yaml` glob expands to the literal
# string and would be grepped as a filename.
workflows=()
while IFS= read -r f; do
  [[ -n "$f" ]] && workflows+=("$f")
done < <(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)

paths=""
if ((${#workflows[@]} > 0)); then
  # Non-comment lines only: a comment naming a path is prose, not a reference.
  body="$(grep -hvE '^[[:space:]]*#' "${workflows[@]}" 2>/dev/null)"

  # By syntax — filename-agnostic. Quotes and $-expansions are stripped so
  # `-r "$semgrep_lock"` resolves through the assignment that defined it, which the
  # second pattern below catches on its own line.
  by_syntax="$(printf '%s\n' "$body" |
    grep -oE '(-r|--requirement)[[:space:]]+"?[.a-zA-Z0-9_/-]+"?|[a-zA-Z_]*lock[a-zA-Z_]*=[[:space:]]*"?[.a-zA-Z0-9_/-]+"?' |
    sed -E 's/^(-r|--requirement)[[:space:]]+//; s/^[a-zA-Z_]*=[[:space:]]*//; s/"//g' |
    grep -E '/' || true)"

  # By name — syntax-agnostic. Needs at least one directory segment: review-reusable's
  # Claude prompt says "pip `requirements.txt` with hashes" as English, and a bare
  # filename is not a path.
  by_name="$(printf '%s\n' "$body" |
    grep -oE '[.a-zA-Z0-9_-]+(/[.a-zA-Z0-9_-]+)*/requirements\.txt' || true)"

  paths="$(printf '%s\n%s\n' "$by_syntax" "$by_name" | grep -vE '^$' | sort -u)"
fi

# A lint that finds nothing to check must fail, not pass. If the workflows stop
# matching (restructured install step, a spelling neither pattern knows), silence here
# would read as "all locks present" while checking zero of them — the same
# absent-reads-as-clean bug this lint exists to catch.
if [[ -z "$paths" ]]; then
  echo "lint-workflow-lock-paths: no lock path found in .github/workflows/" >&2
  echo "  the workflows install from locks; matching zero of them means this lint has" >&2
  echo "  gone blind. Fix the matcher rather than deleting the check." >&2
  exit 1
fi

# `git ls-files`, not `[[ -f ]]`: an untracked file exists locally and is absent in
# CI's fresh checkout, which is exactly the state that would ship a dead detector
# while passing on the author's machine.
missing=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  git ls-files --error-unmatch "$p" >/dev/null 2>&1 || missing+=("$p")
done <<<"$paths"

if ((${#missing[@]} > 0)); then
  echo "lint-workflow-lock-paths: workflow installs from a lock that is not a tracked file:" >&2
  for p in "${missing[@]}"; do
    echo "  ${p}" >&2
  done
  echo "  a missing semgrep lock is reported as 'not run', not as a failure, so this" >&2
  echo "  would disable the detector with CI still green. Fix the path or track the file." >&2
  exit 1
fi

count="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
echo "lint-workflow-lock-paths: ${count} workflow-referenced locks are tracked files"
exit 0
