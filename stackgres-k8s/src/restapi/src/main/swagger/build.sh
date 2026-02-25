#!/bin/sh

set -e

BASE_PATH="$(dirname "$0")"
SCHEMAS_PATH="$BASE_PATH/schemas"
APIWEB_PATH="$BASE_PATH/../../.."
SWAGGER_YAML_FILE="$APIWEB_PATH/target/openapi.yaml"
SWAGGER_JSON_FILE="$APIWEB_PATH/target/openapi.yaml"
MERGED_SWAGGER_YAML_FILE="$APIWEB_PATH/target/swagger-merged.yaml"
MERGED_SWAGGER_JSON_FILE="$APIWEB_PATH/target/swagger-merged.json"
STACKGRES_K8S_PATH="$APIWEB_PATH/../.."
CRDS_PATH="$STACKGRES_K8S_PATH/src/common/src/main/resources/crds"

DEBUG="$(echo $- | grep -q x && echo true || echo false)"

SWAGGER_JSON_FILE="$APIWEB_PATH/target/openapi.json"

# Phase 1: Expand $refs within components using iterative walk
echo "Expanding swagger refs"
ITERATION=0
MAX_ITERATIONS=10
REMAINING_REFS="$(jq '
  [.components | .. | objects | select(has("$ref")) | ."$ref"
    | select(startswith("#/components/schemas/"))] | length
  ' "$SWAGGER_JSON_FILE")"
while [ "$REMAINING_REFS" -gt 0 ] && [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  jq --argjson debug "$DEBUG" '
    .components.schemas as $schemas
    | .components |= walk(
        if type == "object" and has("$ref") and (."$ref" | startswith("#/components/schemas/"))
        then
          (."$ref" | split("/") | .[-1]) as $name
          | if $schemas[$name] != null
            then (if $debug then ["Expanded $ref", $name] | debug else . end) | $schemas[$name]
            else .
            end
        else .
        end
      )
  ' "$SWAGGER_JSON_FILE" > "$SWAGGER_JSON_FILE.tmp"
  mv "$SWAGGER_JSON_FILE.tmp" "$SWAGGER_JSON_FILE"
  REMAINING_REFS="$(jq '
    [.components | .. | objects | select(has("$ref")) | ."$ref"
      | select(startswith("#/components/schemas/"))] | length
    ' "$SWAGGER_JSON_FILE")"
done

if [ "$REMAINING_REFS" -gt 0 ]
then
  echo "Some \$ref were not expanded:"
  echo
  jq -c '[.components | .. | objects | select(has("$ref")) | ."$ref"
    | select(startswith("#/components/schemas/"))]' "$SWAGGER_JSON_FILE"
  exit 1
fi

# Phase 2: Merge types from schema and CRD files
SCHEMAS_PATHS="$(ls -1 "$SCHEMAS_PATH"/*.yaml | tr '\n' ' ')"
CRD_PATHS="$(ls -1 "$CRDS_PATH"/*.yaml | tr '\n' ' ')"
echo "Merging types from $(ls -1 "$SCHEMAS_PATH"/*.yaml | tr '\n' ' ')"

SCHEMAS_FILES="$(echo "$SCHEMAS_PATHS" | tr ' ' '\n' | jq -R '[.,inputs]')"
CRD_FILES="$(echo "$CRD_PATHS" | tr ' ' '\n' | jq -R '[.,inputs]')"

# Convert schema and CRD YAML files to JSON arrays (single yq -s call each)
yq -s '.' $SCHEMAS_PATHS > "$APIWEB_PATH/target/schemas.json"
yq -s '.' $CRD_PATHS > "$APIWEB_PATH/target/crds.json"

jq --argjson debug "$DEBUG" \
   --argjson schema_names "$SCHEMAS_FILES" \
   --argjson crd_names "$CRD_FILES" \
   --slurpfile schemas_arr "$APIWEB_PATH/target/schemas.json" \
   --slurpfile crds_arr "$APIWEB_PATH/target/crds.json" \
  "$(cat << 'EOF'
  $schemas_arr[0] as $schemas | $crds_arr[0] as $crds
  | reduce range($schemas | length) as $i (.;
      . as $accumulator
      | $schemas[$i] as $file
      | $schema_names[$i] as $schema_name
      | if $file.type == null
        then error("Field .type not specified for " + $schema_name)
        else . end
      | if $file.crdFile == null and $file.schema == null
        then error("Field .schema not specified for " + $schema_name)
        else . end
      | (
        if $file.crdFile != null
        then
          ($crd_names | to_entries[] | select(.value | endswith("/" + $file.crdFile)).key) as $crd_index
          | (if $debug then [ "Merged CRD", $file.type, $file.crdFile, $crd_index, $crds[$crd_index].spec.versions[0].schema.openAPIV3Schema ] | debug else . end)
          | (
              {schema: {($file.type): $crds[$crd_index].spec.versions[0].schema.openAPIV3Schema}}
              * $file
            ).schema[$file.type]
          | {($file.type): .}
        else
          {($file.type): $file.schema[$file.type]}
        end
        ) as $added
          | (if $debug then [ "Source DTO", $file.type, $accumulator.components.schemas[$file.type] ] | debug else . end)
          | (if $debug then [ "Added DTO", $file.type, $added ] | debug else . end)
          | (if $debug then [ "Merged DTO", $file.type, $added ] | debug else . end)
          | $accumulator *
            {
              components: {
                schemas: $added
              }
            }
    )
EOF
  )" "$SWAGGER_JSON_FILE" > "$SWAGGER_JSON_FILE.tmp"
mv "$SWAGGER_JSON_FILE.tmp" "$SWAGGER_JSON_FILE"

# Phase 3: Remove orphan types (single jq pass)
KNOWN_TYPES_JSON="$(jq '[.[].type]' "$APIWEB_PATH/target/schemas.json")"
ORPHAN_TYPES="$(jq -r --argjson known "$KNOWN_TYPES_JSON" '
  .components.schemas | keys[] | select(. as $k | $known | index($k) | not)
' "$SWAGGER_JSON_FILE")"

echo "Removing orphan types $ORPHAN_TYPES"
jq --argjson known "$KNOWN_TYPES_JSON" '
  .components.schemas |= with_entries(select(.key | IN($known[])))
  | walk(
      if type == "object" and has("$ref") and (."$ref" | startswith("#/components/schemas/"))
      then
        (."$ref" | split("/") | .[-1]) as $name
        | if ($name | IN($known[])) then . else del(."$ref") end
      else .
      end
    )
' "$SWAGGER_JSON_FILE" > "$SWAGGER_JSON_FILE.tmp"
mv "$SWAGGER_JSON_FILE.tmp" "$SWAGGER_JSON_FILE"

# Phase 4: Validate required vs defined paths
REQUIRED_PATHS="$(jq -r '
  . as $o | paths | select(.[0] == "paths" and .[-1] == "$ref")
  | . as $a | $o | getpath($a) | split("/") | .[length - 1]
' "$SWAGGER_JSON_FILE" | sort | uniq)"
DEFINED_PATHS="$(jq -r '
  paths | select(.[0] == "components" and .[1] == "schemas" and (. | length) == 3)
  | .[length - 1]
' "$SWAGGER_JSON_FILE" | sort | uniq)"
if [ "$REQUIRED_PATHS" != "$DEFINED_PATHS" ]
then
  echo "Some types are missing, please add them to the stackgres-k8s/src/restapi/src/main/swagger folder."
  echo
  echo "Required types:"
  echo
  echo "$REQUIRED_PATHS"
  echo
  echo "Defined types:"
  echo
  echo "$DEFINED_PATHS"
  echo
  exit 1
fi

# Phase 4b: Validate no null paths
NULL_PATHS="$(jq -c -r "$(cat << 'EOF'
  def allpaths:
    def conditional_recurse(f):  def r: ., (select(.!=null) | f | r); r;
    path(conditional_recurse(.[]?)) | select(length > 0);

  . as $o|allpaths|. as $a|select(($o | getpath($a)) == null)
EOF
  )" "$SWAGGER_JSON_FILE")"

if [ -n "$NULL_PATHS" ]
then
  echo "Some fields are null, please review files in the stackgres-k8s/src/restapi/src/main/swagger folder for the following paths:"
  echo
  echo "$NULL_PATHS"
  echo
  exit 1
fi

# Phase 5: Output
cp "$SWAGGER_JSON_FILE" "$MERGED_SWAGGER_JSON_FILE"
yq -y '.' "$SWAGGER_JSON_FILE" > "$MERGED_SWAGGER_YAML_FILE"
