#!/bin/sh

set -e

# Documentation YAML Snippet Validator
# Validates YAML code blocks in markdown docs against CRD OpenAPI v3 schemas

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DOC_DIR="$REPO_ROOT/doc/content/en"
CRD_DIR="$REPO_ROOT/stackgres-k8s/src/common/src/main/resources/crds"
VERBOSE=0
SINGLE_FILE=""

usage() {
  echo "Usage: $0 [--doc-dir DIR] [--crd-dir DIR] [-v|--verbose] [-f|--file FILE]"
  echo ""
  echo "Validates YAML code blocks in documentation against CRD schemas."
  echo ""
  echo "Options:"
  echo "  --doc-dir DIR    Documentation directory (default: doc/content/en)"
  echo "  --crd-dir DIR    CRD definitions directory"
  echo "  -v, --verbose    Show all blocks including UNCHECKED and SKIPPED"
  echo "  -f, --file FILE  Validate a single file"
  echo "  -h, --help       Show this help"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --doc-dir)  DOC_DIR="$2"; shift 2 ;;
    --crd-dir)  CRD_DIR="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -f|--file)  SINGLE_FILE="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1" >&2; exit 4 ;;
  esac
done

TMP_DIR="$(mktemp -d)"
cleanup() {
  if [ "$CHECK_KEEP_TEMP" != 1 ]
  then
    rm -rf "$TMP_DIR"
  fi
}
trap 'cleanup' EXIT

mkdir -p "$TMP_DIR/schemas" "$TMP_DIR/blocks"

RESULTS_FILE="$TMP_DIR/results.count"
ERRORS_LOG="$TMP_DIR/errors.log"
: > "$RESULTS_FILE"
: > "$ERRORS_LOG"

log_verbose() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "$1"
  fi
}

# ─── Step 1: Load and relax CRD schemas ───────────────────────────────

JQ_RELAX_FILTER='
def relax:
  if type == "object" then
    del(.required)
    | del(.pattern, .maxLength, .minLength, .minimum, .maximum, .format, .enum)
    | if .type then
        if (.type | type) == "string" then
          .type = [.type, "null"]
        else
          .
        end
      else
        .
      end
    | if .properties then
        .properties |= with_entries(.value |= relax)
        | if has("additionalProperties") | not then
            .additionalProperties = false
          else
            .
          end
      else
        .
      end
    | if .items then
        .items |= relax
      else
        .
      end
    | if .additionalProperties then
        if (.additionalProperties | type) == "object" then
          .additionalProperties |= relax
        else
          .
        end
      else
        .
      end
    | if .oneOf then .oneOf |= map(relax) else . end
    | if .anyOf then .anyOf |= map(relax) else . end
    | if .allOf then .allOf |= map(relax) else . end
  else
    .
  end;

relax
| .properties.apiVersion = {"type": ["string", "null"]}
| .properties.kind = {"type": ["string", "null"]}
| .properties.metadata.additionalProperties = true
'

echo "Loading CRD schemas..."

for crd_file in "$CRD_DIR"/*.yaml; do
  kind="$(yq -r '.spec.names.kind' "$crd_file")"
  versions="$(yq -r '.spec.versions[].name' "$crd_file")"
  for version in $versions; do
    schema_file="$TMP_DIR/schemas/${kind}_${version}.json"
    yq ".spec.versions[] | select(.name == \"$version\") | .schema.openAPIV3Schema" "$crd_file" \
      | jq "$JQ_RELAX_FILTER" > "$schema_file" 2>/dev/null
    if [ -s "$schema_file" ] && [ "$(jq -r '.type // empty' "$schema_file" 2>/dev/null)" != "" ]; then
      log_verbose "  Loaded schema: ${kind}/${version}"
    else
      echo "  WARNING: Failed to load schema for ${kind}/${version}" >&2
      rm -f "$schema_file"
    fi
  done
done

schema_count="$(find "$TMP_DIR/schemas" -name '*.json' | wc -l | tr -d ' ')"
echo "Loaded $schema_count schemas"

# ─── Step 2: Extract YAML blocks from markdown ────────────────────────

# AWK script that extracts YAML blocks from a markdown file.
# For each block, writes a separate file: blocks/NNNN.yaml
# and appends a metadata line to blocks/index.tsv:
#   BLOCK_NUM<TAB>LINE_NUM<TAB>ANNOTATION
extract_blocks() {
  local md_file="$1"
  local blocks_dir="$2"

  awk -v blocks_dir="$blocks_dir" '
    BEGIN {
      in_yaml = 0
      in_front_matter = 0
      fm_seen = 0
      block_num = 0
      block_line = 0
      prev1 = ""
      prev2 = ""
      prev3 = ""
    }

    # Front matter detection (first --- block at start of file)
    NR == 1 && /^---[[:space:]]*$/ {
      in_front_matter = 1
      next
    }
    in_front_matter && /^---[[:space:]]*$/ {
      in_front_matter = 0
      fm_seen = 1
      next
    }
    in_front_matter { next }

    # YAML code fence start
    !in_yaml && /^```(yaml|yml)[[:space:]]*$/ {
      in_yaml = 1
      block_line = NR
      block_file = blocks_dir "/" sprintf("%04d", block_num) ".yaml"

      # Check preceding lines for doc-check annotations
      annotation = ""
      if (prev1 ~ /<!-- *doc-check:/) annotation = prev1
      else if (prev2 ~ /<!-- *doc-check:/) annotation = prev2
      else if (prev3 ~ /<!-- *doc-check:/) annotation = prev3

      next
    }

    # Code fence end
    in_yaml && /^```[[:space:]]*$/ {
      in_yaml = 0
      close(block_file)
      # Write index entry
      print block_num "\t" block_line "\t" annotation >> (blocks_dir "/index.tsv")
      block_num++
      next
    }

    # Inside YAML block - write to file
    in_yaml {
      print $0 >> block_file
      next
    }

    # Track previous lines
    { prev3 = prev2; prev2 = prev1; prev1 = $0 }
  ' "$md_file"
}

# ─── Step 3: Validate a single YAML document ──────────────────────────

validate_yaml_doc() {
  local rel_path="$1"
  local line_num="$2"
  local yaml_file="$3"
  local forced_kind="$4"

  # Convert to JSON
  local json_file="$(mktemp -u)"
  json_file="$TMP_DIR/${json_file##*/tmp.}-validate.json"
  if ! yq '.' "$yaml_file" > "$json_file" 2>/dev/null; then
    echo "YAML_ERROR" >> "$RESULTS_FILE"
    echo "WARNING: $rel_path:$line_num: YAML_ERROR (could not parse YAML)" >&2
    return
  fi

  # Check if the JSON is a valid object
  local json_type
  json_type="$(jq -r 'type' "$json_file" 2>/dev/null)" || true
  if [ "$json_type" != "object" ]; then
    echo "YAML_ERROR" >> "$RESULTS_FILE"
    echo "WARNING: $rel_path:$line_num: YAML_ERROR (not a YAML mapping)" >&2
    return
  fi

  local detected_kind=""
  local detected_version=""

  if [ -n "$forced_kind" ]; then
    detected_kind="$forced_kind"
    # Find a version for this kind
    for sf in "$TMP_DIR/schemas/${forced_kind}_"*.json; do
      if [ -f "$sf" ]; then
        detected_version="$(basename "$sf" .json | sed "s/^${forced_kind}_//")"
        break
      fi
    done
  else
    # Auto-detect kind and apiVersion
    detected_kind="$(jq -r '.kind // empty' "$json_file" 2>/dev/null)"
    local api_version
    api_version="$(jq -r '.apiVersion // empty' "$json_file" 2>/dev/null)"

    # Only validate SG* kinds with stackgres.io apiVersion
    case "$detected_kind" in
      SG*)
        case "$api_version" in
          stackgres.io/*)
            detected_version="${api_version#stackgres.io/}"
            ;;
          *)
            echo "UNCHECKED" >> "$RESULTS_FILE"
            log_verbose "$rel_path:$line_num: UNCHECKED (SG kind without stackgres.io apiVersion)"
            return
            ;;
        esac
        ;;
      *)
        echo "UNCHECKED" >> "$RESULTS_FILE"
        log_verbose "$rel_path:$line_num: UNCHECKED (not a StackGres resource)"
        return
        ;;
    esac
  fi

  if [ -z "$detected_kind" ] || [ -z "$detected_version" ]; then
    echo "UNCHECKED" >> "$RESULTS_FILE"
    log_verbose "$rel_path:$line_num: UNCHECKED (could not determine kind/version)"
    return
  fi

  # Find schema
  local schema_file="$TMP_DIR/schemas/${detected_kind}_${detected_version}.json"
  if [ ! -f "$schema_file" ]; then
    echo "UNCHECKED" >> "$RESULTS_FILE"
    log_verbose "$rel_path:$line_num: [$detected_kind/$detected_version] UNCHECKED (no schema found)"
    return
  fi

  # Validate with yajsv
  local val_output
  val_output="$(yajsv -s "$schema_file" "$json_file" 2>&1)" || true

  case "$val_output" in
    *pass*)
      echo "VALID" >> "$RESULTS_FILE"
      log_verbose "$rel_path:$line_num: [$detected_kind/$detected_version] VALID"
      ;;
    *fail*)
      echo "ERROR" >> "$RESULTS_FILE"
      local errors
      errors="$(echo "$val_output" | sed "s|$json_file: ||g" | sed 's/^[[:space:]]*//')"
      echo "$rel_path:$line_num: [$detected_kind/$detected_version] $errors"
      echo "$rel_path:$line_num: [$detected_kind/$detected_version] $errors" >> "$ERRORS_LOG"
      ;;
    *)
      echo "YAML_ERROR" >> "$RESULTS_FILE"
      echo "WARNING: $rel_path:$line_num: [$detected_kind/$detected_version] VALIDATION_ERROR: $val_output" >&2
      ;;
  esac
}

# ─── Step 3b: Process a single YAML block ─────────────────────────────

process_block() {
  local rel_path="$1"
  local line_num="$2"
  local block_file="$3"
  local annotation="$4"

  # Check for skip annotation
  case "$annotation" in
    *doc-check:skip*)
      echo "SKIP" >> "$RESULTS_FILE"
      log_verbose "$rel_path:$line_num: SKIPPED (doc-check:skip)"
      return
      ;;
  esac

  # Extract forced kind from annotation
  local forced_kind=""
  case "$annotation" in
    *doc-check:kind=*)
      forced_kind="$(echo "$annotation" | sed 's/.*doc-check:kind=\([A-Za-z]*\).*/\1/')"
      ;;
  esac

  # Strip heredoc wrapping: remove first line if it matches cat<<EOF pattern, and last EOF line
  local cleaned_file="$TMP_DIR/cleaned_block.yaml"
  if head -1 "$block_file" | grep -q 'cat.*<<.*EOF'; then
    # Remove first line (heredoc header) and last line if it's EOF
    sed '1d' "$block_file" | sed '${/^EOF[[:space:]]*$/d;}' > "$cleaned_file"
  else
    cp "$block_file" "$cleaned_file"
  fi

  # Check if file has content
  if [ ! -s "$cleaned_file" ]; then
    return
  fi

  # Check for multi-document YAML (--- separators)
  if grep -q '^---[[:space:]]*$' "$cleaned_file"; then
    # Split into separate documents
    local doc_idx=0
    local doc_file="$TMP_DIR/split_doc_${doc_idx}.yaml"
    : > "$doc_file"

    while IFS= read -r line; do
      case "$line" in
        ---*)
          if [ -s "$doc_file" ]; then
            validate_yaml_doc "$rel_path" "$line_num" "$doc_file" "$forced_kind"
            doc_idx=$((doc_idx + 1))
            doc_file="$TMP_DIR/split_doc_${doc_idx}.yaml"
          fi
          : > "$doc_file"
          ;;
        *)
          echo "$line" >> "$doc_file"
          ;;
      esac
    done < "$cleaned_file"

    # Process last document
    if [ -s "$doc_file" ]; then
      validate_yaml_doc "$rel_path" "$line_num" "$doc_file" "$forced_kind"
    fi

    # Cleanup split files
    local i=0
    while [ $i -le $doc_idx ]; do
      rm -f "$TMP_DIR/split_doc_${i}.yaml"
      i=$((i + 1))
    done
  else
    validate_yaml_doc "$rel_path" "$line_num" "$cleaned_file" "$forced_kind"
  fi
}

# ─── Main: process files ──────────────────────────────────────────────

echo ""
echo "Validating documentation YAML snippets..."
echo ""

process_file() {
  local md_file="$1"
  local rel_path="${md_file#"$REPO_ROOT"/}"
  local file_blocks_dir="$TMP_DIR/blocks/current"

  rm -rf "$file_blocks_dir"
  mkdir -p "$file_blocks_dir"

  extract_blocks "$md_file" "$file_blocks_dir"

  # Process extracted blocks
  if [ ! -f "$file_blocks_dir/index.tsv" ]; then
    return
  fi

  while IFS='	' read -r block_num block_line annotation; do
    local block_file="$file_blocks_dir/$(printf '%04d' "$block_num").yaml"
    if [ -f "$block_file" ]; then
      process_block "$rel_path" "$block_line" "$block_file" "$annotation"
    fi
  done < "$file_blocks_dir/index.tsv"
}

if [ -n "$SINGLE_FILE" ]; then
  if [ ! -f "$SINGLE_FILE" ]; then
    echo "ERROR: File not found: $SINGLE_FILE" >&2
    exit 4
  fi
  process_file "$SINGLE_FILE"
else
  find "$DOC_DIR" -name '*.md' | sort | while read -r md_file; do
    process_file "$md_file"
  done
fi

# ─── Step 4: Report results ───────────────────────────────────────────

COUNT_VALID=$(grep -c '^VALID$' "$RESULTS_FILE" 2>/dev/null || true)
COUNT_SKIPPED=$(grep -c '^SKIP$' "$RESULTS_FILE" 2>/dev/null || true)
COUNT_UNCHECKED=$(grep -c '^UNCHECKED$' "$RESULTS_FILE" 2>/dev/null || true)
COUNT_YAML_ERROR=$(grep -c '^YAML_ERROR$' "$RESULTS_FILE" 2>/dev/null || true)
COUNT_ERRORS=$(grep -c '^ERROR$' "$RESULTS_FILE" 2>/dev/null || true)

# Ensure they are numbers (grep -c returns empty string if file is empty with || true)
COUNT_VALID=${COUNT_VALID:-0}
COUNT_SKIPPED=${COUNT_SKIPPED:-0}
COUNT_UNCHECKED=${COUNT_UNCHECKED:-0}
COUNT_YAML_ERROR=${COUNT_YAML_ERROR:-0}
COUNT_ERRORS=${COUNT_ERRORS:-0}

COUNT_TOTAL=$((COUNT_VALID + COUNT_SKIPPED + COUNT_UNCHECKED + COUNT_YAML_ERROR + COUNT_ERRORS))

echo ""
echo "=== Documentation YAML Snippet Validation Summary ==="
echo "Total: $COUNT_TOTAL | VALID: $COUNT_VALID | SKIPPED: $COUNT_SKIPPED | UNCHECKED: $COUNT_UNCHECKED | YAML_ERROR: $COUNT_YAML_ERROR | ERRORS: $COUNT_ERRORS"
echo ""

if [ "$COUNT_ERRORS" -gt 0 ]; then
  echo "Validation errors:"
  cat "$ERRORS_LOG"
  echo ""
  exit 1
fi

exit 0
