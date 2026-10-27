#!/bin/bash
#SBATCH --job-name=reduction_archive
#SBATCH --output=reduction_archive_%j.out
#SBATCH --error=reduction_archive_%j.err
#SBATCH --time=00:30:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4GB
#
# archive.sh  --  processMeerKAT_llus reduction archiver
#
# Run this INSIDE a single galaxy/target reduction directory once you are
# completely finished with it. It sweeps the products worth keeping into one
# archive folder, then (only when you confirm) permanently deletes everything
# else in that directory to reclaim space.
#
# What is KEPT (archived), matched at the TOP LEVEL of the current directory:
#   - *science_image*   all science-imaging products. Matching by name (not by
#                       target) automatically covers the plain images, the
#                       .alpha / .alpha.error maps (stokes != 'I'), the
#                       .cube.* products and SPW_MFSs/ (spw_cube = True), and the
#                       .katbeam* products (pbcorr = True).
#   - SPW_MFSs/         per-SPW image folder (spw_cube = True).
#   - plots/            diagnostic plots.
#   - the target MMS    the galaxy's own .mms/.ms, identified from the config
#                       [fields] targetfields (calibrator MMSs are NOT kept).
#   - *.png             stray plot images.
#   --- provenance / "record of what was done" ----------------------------
#   - *.txt             the input config file.
#   - .config.tmp       the live config the pipeline actually ran with.
#   - logs/             SLURM .out/.err and CASA logs.
#   - *.log             loose CASA logs that live OUTSIDE logs/ (top level and
#                       inside each per-SPW dir).
#   - *.sbatch          every generated per-step SLURM job script.
#   - jobScripts/       timestamped helper scripts + the timestamped config copy.
#   - *.sh              submit_pipeline.sh, all control scripts (summary/
#                       fullSummary/allSPW_*/killJobs/findErrors/displayTimes/
#                       cleanup, any case) and user-added helpers.
#   - *.py              user-added helper scripts (e.g. make_alpha_*).
#
# For multi-SPW runs the same provenance (logs/, jobScripts/, *.sbatch, control
# *.sh, config) is also swept out of each per-SPW *MHz*/ directory into
# ${ARCHIVE_DIR}/<spw>/ before the data-heavy SPW directory itself is deleted.
#
# What is DELETED (everything else at the top level), e.g.:
#   - per-SPW *MHz* directories (their MMS data), calibrator .mms,
#   - .gcal*/.bcal* tables, *.contcube / *.contcube.fits quick-look diagnostics.
#
# Nothing is deleted unless you pass -d/--confirm-delete (or set
# CONFIRM_DELETE=true below); by default you only get a preview.
# The config, logs and all job scripts are archived as a record of the run.

set -uo pipefail

#############################  DEFAULTS  #############################
CONFIRM_DELETE=false           # false = preview only (safe). true = actually delete.
ARCHIVE_DIR="RC_PMKT_archive"  # folder that kept products are moved into.
CONFIG=""                      # config to read [fields] targetfields from (auto-detected).
TARGET=""                      # comma-separated target name(s); overrides the config.
DELETE_UNREC=""                # ''=ask (if interactive), 'yes'=delete, 'no'=keep unrecognised.
#####################################################################

usage() {
cat <<EOF
Usage: archive.sh [options]   (run inside one galaxy/target reduction directory)

Archives the processMeerKAT_llus products worth keeping into ./${ARCHIVE_DIR}/,
then (only if enabled) permanently deletes everything else in this directory.

Kept (top level): science products -- *science_image*, SPW_MFSs/, plots/, *.png,
the target's own .mms/.ms -- plus the full run record: the config (*.txt and
.config.tmp), logs/, submit_pipeline.sh, *.sbatch, jobScripts/ and the *.sh
control scripts. Per-SPW *MHz*/ logs & job scripts are archived too.
Deleted: per-SPW *MHz* data dirs, calibrator MMSs, .gcal*, *.contcube[.fits], etc.

Options:
  -t, --target NAME[,NAME2,...]
                    Target field name(s) whose MMS to keep (e.g. --target PGC31359).
                    If omitted, the target is automatically read from .config.tmp
  -C, --config FILE
                    processMeerKAT config to read 'targetfields' from ([fields]).
                    Auto-detected if omitted (.config.tmp, then first *.txt).
  -d, --confirm-delete
                    Actually perform the cleanup deletion (default: preview only).
  -a, --archive-dir DIR
                    Name of the archive folder (default: ${ARCHIVE_DIR}).
  -u, --delete-unrecognised
                    Also delete UNRECOGNISED items (anything that is neither kept
                    nor recognised pipeline bulk) without prompting. Default: ask
                    interactively, and KEEP them when running non-interactively.
      --keep-unrecognised
                    Never delete unrecognised items (leave them in place); skips
                    the prompt. Useful for unattended/batch runs.
  -h, --help        Show this help and exit.

Notes:
  * Safe by default: nothing is deleted until you pass -d/--confirm-delete.
  * The config, logs and all job scripts are archived as a record of the run.
  * If no target can be resolved, ALL top-level .mms/.ms are kept.
  * Recognised bulk (calibrator MMSs, .gcal*, *_im_N, *.contcube[.fits], *MHz*
    dirs, caches) is deleted directly; anything else unrecognised is listed and
    you are asked before it is removed (see -u / --keep-unrecognised).

Examples:
  archive.sh --help
  cd pgc31359 && archive.sh                 # preview (auto-reads .config.tmp)
  cd pgc31359 && archive.sh --confirm-delete
  archive.sh --target PGC31359 -d
EOF
}

#############################  ARG PARSING  #########################
# Require an operand for value-taking flags. Without this guard a trailing flag
# (e.g. `archive.sh --target`) would leave <2 params, making `shift 2` a no-op
# and spinning the while-loop forever (there is no `set -e` to break out).
need_val() { [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; echo "Try --help." >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)         need_val "$@"; TARGET="$2"; shift 2 ;;
        -C|--config)         need_val "$@"; CONFIG="$2"; shift 2 ;;
        -a|--archive-dir)    need_val "$@"; ARCHIVE_DIR="$2"; shift 2 ;;
        -d|--confirm-delete) CONFIRM_DELETE=true; shift ;;
        -u|--delete-unrecognised) DELETE_UNREC="yes"; shift ;;
        --keep-unrecognised) DELETE_UNREC="no"; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; echo "Try --help." >&2; exit 2 ;;
    esac
done

#############################  RESOLVE TARGET(S)  ###################
# Prefer --target; otherwise read 'targetfields' from the config's [fields] section.
if [[ -z "$TARGET" ]]; then
    if [[ -z "$CONFIG" ]]; then
        if [[ -f ".config.tmp" ]]; then
            CONFIG=".config.tmp"
        else
            CONFIG=$(ls -1 ./*.txt 2>/dev/null | head -n 1 || true)
        fi
    fi
    if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
        raw=$(grep -E '^[[:space:]]*targetfields[[:space:]]*=' "$CONFIG" | head -n 1 | cut -d= -f2-)
        raw="${raw%%#*}"                                                  # strip inline comment
        raw="$(echo "$raw" | tr -d "[]'\"" | xargs 2>/dev/null || true)"  # strip quotes/brackets/spaces
        TARGET="$raw"
        [[ -n "$TARGET" ]] && echo "Target(s) '$TARGET' read from config '$CONFIG'."
    fi
fi

declare -a TARGETS=()
[[ -n "$TARGET" ]] && IFS=',' read -r -a TARGETS <<< "$TARGET"

#############################  BUILD KEEP EXPRESSION  ###############
# Category matches that hold regardless of which pipeline features were enabled.
# Category matches shared by the top-level sweep and the per-SPW sweep below.
# Kept separate (without the target MMS clause) so the per-SPW sweep can reuse it.
declare -a RECORD_MATCH=( '(' -type d -name 'plots' ')' \
                       -o '(' -type d -name 'SPW_MFSs' ')' \
                       -o '(' -type d -name 'logs' ')' \
                       -o '(' -type d -name 'jobScripts' ')' \
                       -o -name '*science_image*' \
                       -o -name '*.png' \
                       -o -name '*.sbatch' \
                       -o -name '*.sh' \
                       -o -name '*.py' \
                       -o -name '*.txt' \
                       -o -name '.config.tmp' \
                       -o -name '*.log' )
# Notes on the script globs: '*.sh' covers submit_pipeline.sh and every control
# script (summary/fullSummary/allSPW_*/killJobs/findErrors/displayTimes/cleanup,
# any case); '*.py' + '*.sh' also capture user-added helpers (e.g. make_alpha_*).
# '*.log' keeps loose CASA logs that live outside logs/ (top level and per-SPW).

# KEEP_INNER = record provenance OR the target MMS/MS, WITHOUT outer parens, so
# both the archive sweep (wraps it as '( ... )') and the delete preview (negates
# it as '! ( ... )') reuse the exact same keep definition.
declare -a KEEP_INNER=( "${RECORD_MATCH[@]}" )

if [[ ${#TARGETS[@]} -gt 0 ]]; then
    for t in "${TARGETS[@]}"; do
        [[ -z "$t" ]] && continue
        # keep the target's own MMS/MS (and its .flagversions); exclude per-SPW *MHz* copies
        KEEP_INNER+=( -o '(' -name "*${t}*.mms*" '!' -name '*MHz*' ')' \
                      -o -name "*${t}*.ms" )
    done
else
    echo "No target resolved (no --target and none in config); conservatively keeping ALL top-level .mms/.ms."
    KEEP_INNER+=( -o '(' -name '*.mms*' '!' -name '*MHz*' ')' -o -name '*.ms' )
fi

declare -a MATCH=( '(' "${KEEP_INNER[@]}" ')' )

# Never archived or deleted: the archive itself, this running script, and this
# archive job's own SLURM logs.
declare -a PROTECT=( ! -name "$ARCHIVE_DIR" ! -name "$(basename "$0")" \
                     ! -name "reduction_archive_*.out" ! -name "reduction_archive_*.err" )

# KNOWN_BULK = reduction by-products we positively recognise as safe to delete.
# Anything left over that is NOT kept and NOT in here is treated as UNRECOGNISED
# and the user is asked before it is removed (so a missing pattern only ever
# causes an extra prompt, never a silent deletion).
declare -a KNOWN_BULK=( -name '*.mms' -o -name '*.mms.flagversions' -o -name '*.ms' \
                        -o -name '*.gcal*' -o -name '*.bcal*' \
                        -o -name '*.contcube' -o -name '*.contcube.fits' \
                        -o -name '*_im_[0-9]*' \
                        -o -name '*MHz*' \
                        -o -name 'caltables*' \
                        -o -name '*-minmax-cache.json' \
                        -o -name '.ipynb_checkpoints' )

#####################  PRE-EXISTING ARCHIVE GUARD  ################
# Re-running into an archive that already exists is common (a half-finished run,
# or a re-reduction). It is only dangerous when an item we would move shares a
# name with something already inside the archive: a silent 'mv' would overwrite
# an archived file, or fail mid-run on a non-empty dir. Detect such COLLISIONS
# up front and refuse, rather than clobbering a previous archive or aborting
# partway. No collisions -> proceed normally (so a half-archived dir still
# completes cleanly).
if [[ -d "$ARCHIVE_DIR" ]]; then
    declare -a COLLISIONS=()
    # top-level items that would be archived into $ARCHIVE_DIR/
    while IFS= read -r -d '' item; do
        base="$(basename "$item")"
        [[ -e "$ARCHIVE_DIR/$base" ]] && COLLISIONS+=( "$base" )
    done < <(find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" "${MATCH[@]}" -print0)
    # per-SPW record items that would be moved into $ARCHIVE_DIR/<spw>/
    shopt -s nullglob
    for spwpath in */ ; do
        spwname="${spwpath%/}"
        [[ "$spwname" == "$ARCHIVE_DIR" ]] && continue
        case "$spwname" in
            *MHz*)
                [[ -d "$ARCHIVE_DIR/$spwname" ]] || continue
                while IFS= read -r -d '' item; do
                    base="$(basename "$item")"
                    [[ -e "$ARCHIVE_DIR/$spwname/$base" ]] && COLLISIONS+=( "$spwname/$base" )
                done < <(find "$spwname" -mindepth 1 -maxdepth 1 '(' "${RECORD_MATCH[@]}" ')' -print0)
                ;;
        esac
    done
    shopt -u nullglob
    if [[ ${#COLLISIONS[@]} -gt 0 ]]; then
        echo "ERROR: archive directory '$ARCHIVE_DIR' already contains items this run would overwrite:" >&2
        printf '  %s\n' "${COLLISIONS[@]}" >&2
        echo "Refusing to proceed, to avoid clobbering a previous archive." >&2
        echo "Use a fresh archive with -a/--archive-dir <newname>, or move/remove the existing '$ARCHIVE_DIR' first." >&2
        exit 3
    fi
fi

#############################  PREVIEW (read-only)  ###############
# Always show, WITHOUT touching anything, exactly what would happen. In the
# default (no -d) mode we stop after this - nothing is moved or deleted.
echo "Top-level items that WOULD be archived into $ARCHIVE_DIR/:"
find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" "${MATCH[@]}" -print
echo ""

echo "Per-SPW provenance that WOULD be preserved under $ARCHIVE_DIR/<spw>/ (extracted before each SPW dir is removed):"
shopt -s nullglob
for spwpath in */ ; do
    spwname="${spwpath%/}"
    [[ "$spwname" == "$ARCHIVE_DIR" ]] && continue
    case "$spwname" in
        *MHz*) find "$spwname" -mindepth 1 -maxdepth 1 '(' "${RECORD_MATCH[@]}" ')' -print ;;
    esac
done
shopt -u nullglob
echo ""

echo "Recognised bulk that WOULD be deleted directly (a per-SPW *MHz* dir is removed only after its provenance above is extracted):"
find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" ! '(' "${KEEP_INNER[@]}" ')' '(' "${KNOWN_BULK[@]}" ')' -print
echo ""

echo "UNRECOGNISED items (neither kept nor recognised bulk) - you will be ASKED before these are deleted:"
if ! find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" ! '(' "${KEEP_INNER[@]}" ')' ! '(' "${KNOWN_BULK[@]}" ')' -print | grep -q .; then
    echo "  (none)"
fi
find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" ! '(' "${KEEP_INNER[@]}" ')' ! '(' "${KNOWN_BULK[@]}" ')' -print
echo ""

if [ "$CONFIRM_DELETE" != true ]; then
    echo "Preview only (read-only) - nothing was moved or deleted."
    echo "Re-run with -d/--confirm-delete to archive the above and delete the recognised bulk."
    echo "Unrecognised items (if any) will be listed again with a yes/no prompt at that point."
    exit 0
fi

#############################  ARCHIVE  ###########################
echo "CONFIRM_DELETE set - archiving the record + science products, then deleting the rest."
mkdir -p "$ARCHIVE_DIR"

# 'mv -t' requires GNU coreutils (present on the ilifu/Linux cluster; NOT on
# BSD/macOS). If the archive mv fails for ANY reason, abort BEFORE cleanup so
# deletion can never remove un-archived data.
if ! find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" "${MATCH[@]}" -exec mv -t "$ARCHIVE_DIR/" {} + ; then
    echo "ERROR: archiving failed - aborting before any deletion so nothing is lost." >&2
    exit 1
fi

# Per-SPW: preserve each *MHz*/ dir's own provenance before the dir is deleted.
shopt -s nullglob
for spwpath in */ ; do
    spwname="${spwpath%/}"
    [[ "$spwname" == "$ARCHIVE_DIR" ]] && continue
    case "$spwname" in
        *MHz*)
            dest="$ARCHIVE_DIR/$spwname"
            echo "Preserving per-SPW record from '$spwname/' into '$dest/'..."
            mkdir -p "$dest"
            if ! find "$spwname" -mindepth 1 -maxdepth 1 '(' "${RECORD_MATCH[@]}" ')' \
                 -exec mv -t "$dest/" {} + ; then
                echo "ERROR: failed to preserve per-SPW record from '$spwname' - aborting before deletion." >&2
                exit 1
            fi
            ;;
    esac
done
shopt -u nullglob
echo "Archive step complete."
echo ""

#############################  CLEANUP  ###########################
# Everything still at the top level (minus PROTECT) is now the delete universe,
# since kept items were already moved into the archive. Split it in two:
#   - recognised bulk  -> deleted directly
#   - unrecognised     -> listed, and removed only with the user's consent
echo "Deleting recognised reduction bulk..."
find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" '(' "${KNOWN_BULK[@]}" ')' -exec rm -rf {} +

# Gather the unrecognised leftovers (not bulk, not kept/protected).
declare -a UNREC=()
while IFS= read -r -d '' item; do
    UNREC+=( "${item#./}" )
done < <(find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" ! '(' "${KNOWN_BULK[@]}" ')' -print0)

if [[ ${#UNREC[@]} -eq 0 ]]; then
    echo "No unrecognised items remain."
    echo "Cleanup complete."
else
    echo ""
    echo "The following ${#UNREC[@]} item(s) are UNRECOGNISED (neither kept nor recognised bulk):"
    printf '  %s\n' "${UNREC[@]}"
    echo ""

    # Decide: explicit flag wins; otherwise ask if interactive, else keep (safe).
    answer="$DELETE_UNREC"
    if [[ -z "$answer" ]]; then
        if [ -t 0 ]; then
            read -r -p "Delete these ${#UNREC[@]} unrecognised item(s) too? [y/N] " reply
            case "$reply" in [Yy]*) answer="yes" ;; *) answer="no" ;; esac
        else
            answer="no"
            echo "(non-interactive run: keeping unrecognised items in place; pass -u to delete them)"
        fi
    fi

    if [[ "$answer" == "yes" ]]; then
        echo "Deleting unrecognised items..."
        find . -mindepth 1 -maxdepth 1 "${PROTECT[@]}" ! '(' "${KNOWN_BULK[@]}" ')' -exec rm -rf {} +
        echo "Cleanup complete."
    else
        echo "Leaving the unrecognised items in place. Everything else is done."
        echo "Cleanup complete (unrecognised items retained)."
    fi
fi
