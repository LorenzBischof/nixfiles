# Run `nixpkgs-review pr` in GitHub Actions through the user's fork. Takes a
# subset of nixpkgs-review's flags and prints one line per PR: its state, and
# whether it was dispatched or what to do instead. Without arguments it lists
# the open PRs involving the user and dispatches nothing.

fork=LorenzBischof/nixpkgs-review-gha
all_systems="x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin"
usage="usage: nixpkgs-review-gha [--post-result] [--systems SYSTEMS] [--tests]
       [-p PACKAGE] [-P SKIP_PACKAGE] [--force] number [number ...]
       nixpkgs-review-gha    (list the queue, dispatch nothing)
--systems defaults to the Linux platforms whose 10.rebuild-* label is not 0;
Darwin runs only when named, e.g. --systems all.
--force also runs drafts, mass rebuilds (501+) and heads that already have a report."

queue=false
[ $# -gt 0 ] || queue=true
post=false
tests=false
force=false
systems=""
extra=()
prs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --post-result) post=true ;;
    --tests) tests=true ;;
    --force) force=true ;;
    --systems) systems=$2 && shift ;;
    -p | --package | -P | --skip-package) extra+=("$1" "$2") && shift ;;
    [0-9]*) prs+=("$1") ;;
    *)
      printf 'unsupported argument: %s\n%s\n' "$1" "$usage" >&2
      exit 2
      ;;
  esac
  shift
done
[ "$systems" != all ] || systems=$all_systems

if [ "$queue" = true ]; then
  # Broad on purpose: it catches backports, which carry no maintainer ping, and
  # leaves the PRs the user merely commented on for the caller to sort out.
  mapfile -t prs < <(gh search prs --repo NixOS/nixpkgs --state open --involves @me \
    -L 100 --json number --jq '.[].number' | sort -n)
  [ ${#prs[@]} -gt 0 ] || { echo "No open PRs involve the user." && exit 0; }
elif [ ${#prs[@]} -eq 0 ]; then
  echo "$usage" >&2 && exit 2
fi

active=$(gh run list -R "$fork" -w review.yml -L 50 --json displayTitle,status,url \
  --jq '.[] | select(.status != "completed") | "\(.displayTitle)\t\(.url)"')

for pr in "${prs[@]}"; do
  # CI's eval labels each platform's rebuild count; no label means it has not
  # finished or failed. platforms lists the systems not labelled 0 (of
  # Darwin only aarch64, to spare the scarce macOS runners), mass the
  # buckets of 501 and up; both comma-separated, "-" if none.
  # shellcheck disable=SC2016 # $r, $platforms and $mass are jq variables
  read -r state draft head evaluated platforms mass title < <(gh pr view "$pr" -R NixOS/nixpkgs \
    --json state,isDraft,headRefOid,labels,title \
    --jq '[.labels[].name | select(startswith("10.rebuild-"))] as $r
      | [if $r | index("10.rebuild-linux: 0") then empty else "x86_64-linux", "aarch64-linux" end,
         if $r | index("10.rebuild-darwin: 0") then empty else "aarch64-darwin" end]
        as $platforms
      | ($r | map(select(test(": (501-1000|1001-2500|2501-5000|5001\\+)$"))
          | ltrimstr("10.rebuild-") | gsub(" "; ""))) as $mass
      | [.state, .isDraft, .headRefOid, $r != [], ($platforms, $mass | join(",") | if . == "" then "-" end), .title]
        | join(" ")')
  # Darwin only when asked for with --systems; aarch64-darwin is always last.
  if [ -z "$systems" ] && [ "$platforms" != - ]; then
    platforms=${platforms%aarch64-darwin} && platforms=${platforms%,} && platforms=${platforms:--}
  fi
  # Our reports name the head commit they reviewed. One line per report, oldest
  # first: "<url> <true if it is for the current head>".
  reports=$(gh api --paginate "repos/NixOS/nixpkgs/issues/$pr/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"nixpkgs-review-gha\") | \"\\(.html_url) \\(.body | contains(\"$head\"))\"")
  report=$(awk '$2 == "true" { print $1 }' <<<"$reports" | tail -n1)
  latest=$(tail -n1 <<<"$reports" | cut -d' ' -f1)
  run=$(grep -P "^review #$pr( |\t)" <<<"$active" | cut -f2 || true)

  tags=""
  [ "$draft" = false ] || tags+=" [draft]"
  [ "$mass" = - ] || tags+=" [mass-rebuild $mass]"
  # final: no run makes sense. held: only with --force, which needs the user's say.
  final=false
  held=false
  [ -z "$tags" ] || held=true
  if [ "$state" != OPEN ]; then
    status=closed detail="PR is $state" final=true
  elif [ -n "$run" ]; then
    status=running detail="follow $run" final=true
  elif [ "$platforms" = - ]; then
    if [ -z "$systems" ]; then
      detail="0 rebuilds on Linux, nothing to build; Darwin only with --systems"
    else
      detail="0 rebuilds on Linux and Darwin, nothing to build"
    fi
    status=no-rebuilds final=true
  elif [ "$evaluated" = false ]; then
    # nixpkgs-review fetches CI's eval and gives up after 10 minutes without it.
    status=pending-eval final=true
    detail="no 10.rebuild-* labels; wait for CI's eval, or re-run it if it failed or was cancelled"
  elif [ -n "$report" ]; then
    status=current detail="report for this head: $report" held=true
  elif [ -n "$latest" ]; then
    status=outdated detail="last report is for an older head: $latest"
  else
    status=missing detail="never reviewed"
  fi

  if [ "$queue" = true ] || [ "$final" = true ] || { [ "$held" = true ] && [ "$force" = false ]; }; then
    if [ "$final" = true ]; then
      next=""
    elif [ "$held" = true ]; then
      next="; ask the user, then \`nixpkgs-review-gha --post-result --force $pr\`"
    else
      next="; run \`nixpkgs-review-gha --post-result $pr\`"
    fi
    echo "#$pr$tags $status: $title; $detail$next"
    continue
  fi

  run_systems=${systems:-${platforms//,/ }}
  args=(-f pr="$pr" -f post-result="$post" -f on-success=nothing -f tests="$tests")
  # Every system is on by default; turn off the ones not asked for.
  for s in $all_systems; do
    if [[ " $run_systems " != *" $s "* ]]; then
      if [[ $s == *darwin ]]; then args+=(-f "$s=no"); else args+=(-f "$s=false"); fi
    fi
  done
  [ ${#extra[@]} -eq 0 ] || args+=(-f extra-args="${extra[*]}")
  gh workflow run review.yml -R "$fork" "${args[@]}" >/dev/null
  echo "#$pr$tags dispatched: $title; on $run_systems (post-result=$post), see \`gh run list -R $fork -w review.yml\`"
done
