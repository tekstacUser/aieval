#!/bin/bash

# ============================================================
# Modulo 4 - Ollama Model Serving with Kubernetes, HPA and Reliability
#
# FINAL EVALUATOR
#
# Technical Evaluation      : 70 marks
# Prompt Engineering Review : 30 marks
# Final                     : 100 marks
#
# AI learner evidence:
#   1. /opt/Test/chatlog.txt
#   2. Dynamic fallback under /opt/userworkspace/*/chatlog.txt
#
# AI evaluator reference files:
#   /opt/Test/strict_md.txt
#   /opt/Test/final_rubrics.txt
#   /opt/Test/output_format.txt
#
# Generated:
#   /opt/Test/ai_raw_response.txt
#   /opt/Test/output1.json
#   /opt/Test/output2.json
#   /opt/Test/results.json
#   /opt/Test/report.json
# ============================================================

export MAVEN_OPTS="-Djansi.force=false"

PROJECT_NAME="modulo4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVITY_ID="${1:-}"

TEST_ROOT="/opt/Test"
TEST_PROJECT="$TEST_ROOT/$PROJECT_NAME"

# ============================================================
# Output files
# ============================================================

AI_OUTPUT="$TEST_ROOT/output1.json"
EVAL_OUTPUT="$TEST_ROOT/output2.json"
RESULTS_OUTPUT="$TEST_ROOT/results.json"
REPORT_OUTPUT="$TEST_ROOT/report.json"

AI_RAW="$TEST_ROOT/ai_raw_response.txt"
EVAL_RAW="$TEST_ROOT/eval_raw.txt"

# ============================================================
# Evaluator reference files
# These must be supplied by the evaluator under /opt/Test.
# ============================================================

STRICT_MD="$TEST_ROOT/strict_md.txt"
FINAL_RUBRICS="$TEST_ROOT/final_rubrics.txt"
OUTPUT_FORMAT="$TEST_ROOT/output_format.txt"

# ============================================================
# Generic failure response
# ============================================================

failure_response() {

    local message="$1"

    local reportData

    reportData="$(jq -n \
        '{
            evaluationdetails: {
                evaluationbreakup: [],
                consolidatedtestcase: {
                    totaltestcases: "16",
                    passedtestcase: "0",
                    failedtestcase: "16"
                }
            }
        }'
    )"

    echo "Grade:=>0.00 <reportData>$reportData</reportData>"
    echo "$message" >&2
}

# ============================================================
# Validate Activity ID
# ============================================================

if [ -z "$ACTIVITY_ID" ]; then

    failure_response "Activity ID is missing."
    exit 1

fi

# ============================================================
# Locate learner project
# ============================================================

SOURCE_PROJECT="/home/tekuser/TekstacLabRoot/$ACTIVITY_ID/ProjectRoot/$PROJECT_NAME"

if [ ! -d "$SOURCE_PROJECT" ]; then

    failure_response \
        "Project directory not found: $SOURCE_PROJECT"

    exit 1

fi

# ============================================================
# Prepare /opt/Test
#
# IMPORTANT:
# Do NOT delete /opt/Test.
#
# The Tekstac evaluator may already have copied:
#   chatlog.txt
#   strict_md.txt
#   final_rubrics.txt
#   output_format.txt
#
# Therefore only replace the learner project directory.
# ============================================================

mkdir -p "$TEST_ROOT" 2>/dev/null

if [ $? -ne 0 ]; then

    failure_response \
        "Unable to create $TEST_ROOT"

    exit 1

fi

rm -rf "$TEST_PROJECT" 2>/dev/null

cp -r "$SOURCE_PROJECT" "$TEST_PROJECT" 2>/dev/null

if [ $? -ne 0 ] || [ ! -d "$TEST_PROJECT" ]; then

    failure_response \
        "Unable to copy learner project to $TEST_PROJECT"

    exit 1

fi

# ============================================================
# IMPORTANT:
# Technical evaluator expects the learner project to be the
# current working directory.
# ============================================================

cd "$TEST_PROJECT" || {

    failure_response \
        "Unable to enter $TEST_PROJECT"

    exit 1

}

# ============================================================
# Locate learner chatlog
#
# Priority:
#
# 1. /opt/Test/chatlog.txt
#
# 2. Dynamically search /opt/userworkspace for a chatlog
#    associated with the current ACTIVITY_ID.
#
# 3. If no activity-specific file is found, use a constrained
#    fallback search only if exactly one chatlog exists.
#
# NEVER hard-code:
#   /opt/userworkspace/109/77579/chatlog.txt
# ============================================================

CHATLOG="$TEST_ROOT/chatlog.txt"

if [ ! -s "$CHATLOG" ]; then

    CHATLOG=""

    # --------------------------------------------------------
    # First dynamic search:
    # Prefer a chatlog whose path contains the Activity ID.
    # --------------------------------------------------------

    if [ -n "$ACTIVITY_ID" ] &&
       [ -d "/opt/userworkspace" ]; then

        CHATLOG_CANDIDATE="$(
            find /opt/userworkspace \
                -type f \
                -name "chatlog.txt" \
                -path "*${ACTIVITY_ID}*" \
                2>/dev/null |
            head -n 1
        )"

        if [ -n "$CHATLOG_CANDIDATE" ] &&
           [ -s "$CHATLOG_CANDIDATE" ]; then

            CHATLOG="$CHATLOG_CANDIDATE"

        fi

    fi

fi

# ============================================================
# Second fallback:
# If /opt/Test/chatlog.txt and Activity-ID matching failed,
# collect all non-empty chatlogs.
#
# Only use one when there is exactly one candidate.
# This prevents accidentally selecting another learner's
# chatlog when multiple workspaces exist.
# ============================================================

if [ -z "$CHATLOG" ] &&
   [ -d "/opt/userworkspace" ]; then

    CHATLOG_COUNT="$(
        find /opt/userworkspace \
            -type f \
            -name "chatlog.txt" \
            -size +0c \
            2>/dev/null |
        wc -l
    )"

    if [ "$CHATLOG_COUNT" -eq 1 ]; then

        CHATLOG="$(
            find /opt/userworkspace \
                -type f \
                -name "chatlog.txt" \
                -size +0c \
                2>/dev/null |
            head -n 1
        )"

    fi

fi

# ============================================================
# Validate AI reference files
# ============================================================

AI_REFERENCE_OK=true
MISSING_REFERENCE=""

for f in \
    "$STRICT_MD" \
    "$FINAL_RUBRICS" \
    "$OUTPUT_FORMAT"
do

    if [ ! -f "$f" ]; then

        AI_REFERENCE_OK=false
        MISSING_REFERENCE="$f"
        break

    fi

done

# ============================================================
# Validate chatlog
# ============================================================

if [ -z "$CHATLOG" ] || [ ! -s "$CHATLOG" ]; then

    CHATLOG_ERROR=true

else

    CHATLOG_ERROR=false

fi

# ============================================================
# Load Haiku API key
# ============================================================

HAIKU_KEY="${COPILOT_HAIKU_API_KEY:-}"

if [ -z "$HAIKU_KEY" ] &&
   [ -f "/etc/tekstac/copilot.env" ]; then

    set -a

    # shellcheck disable=SC1091
    source /etc/tekstac/copilot.env

    set +a

    HAIKU_KEY="${COPILOT_HAIKU_API_KEY:-}"

fi

# ============================================================
# AI failure output
#
# Always preserve the 3 Modulo 4 testcases /30.
# ============================================================

ai_failure() {

    local reason="$1"

    jq -n \
        --arg reason "$reason" \
        '{
            expertise: {
                name: "Prompt Engineering Review",
                testcases: {
                    testcase: [
                        {
                            visible: "yes",
                            name: "Requirement Understanding and Architecture Planning",
                            description:
                                ("Observed Evidence: No valid AI evaluation was produced.\nReason for Score: " + $reason + "\nMissing Evidence: Valid learner prompt-history evaluation."),
                            shortdescription:
                                "Requirement Understanding and Architecture Planning could not be evaluated.",
                            maxmark: "10",
                            score: "0",
                            status: "fail",
                            failmessage: $reason
                        },

                        {
                            visible: "yes",
                            name: "Prompt Quality for Build, Deployment and Debugging",
                            description:
                                ("Observed Evidence: No valid AI evaluation was produced.\nReason for Score: " + $reason + "\nMissing Evidence: Valid learner prompt-history evaluation."),
                            shortdescription:
                                "Prompt Quality for Build, Deployment and Debugging could not be evaluated.",
                            maxmark: "10",
                            score: "0",
                            status: "fail",
                            failmessage: $reason
                        },

                        {
                            visible: "yes",
                            name: "Verification and Validation Strategy",
                            description:
                                ("Observed Evidence: No valid AI evaluation was produced.\nReason for Score: " + $reason + "\nMissing Evidence: Valid learner prompt-history evaluation."),
                            shortdescription:
                                "Verification and Validation Strategy could not be evaluated.",
                            maxmark: "10",
                            score: "0",
                            status: "fail",
                            failmessage: $reason
                        }
                    ]
                }
            }
        }' > "$AI_OUTPUT"
}

# ============================================================
# AI EVALUATION - 20 MARKS
# ============================================================

if [ "$CHATLOG_ERROR" = true ]; then

    ai_failure \
        "Learner chatlog.txt could not be located. Checked /opt/Test and the dynamic /opt/userworkspace paths."

elif [ "$AI_REFERENCE_OK" = false ]; then

    ai_failure \
        "Required AI evaluator reference file is missing: $MISSING_REFERENCE"

elif [ -z "$HAIKU_KEY" ]; then

    ai_failure \
        "COPILOT_HAIKU_API_KEY was not available."

else

    # --------------------------------------------------------
    # Read AI sources
    # --------------------------------------------------------

    CHATLOG_CONTENT="$(cat "$CHATLOG")"
    STRICT_CONTENT="$(cat "$STRICT_MD")"
    RUBRICS_CONTENT="$(cat "$FINAL_RUBRICS")"
    FORMAT_CONTENT="$(cat "$OUTPUT_FORMAT")"

    # --------------------------------------------------------
    # System prompt
    # --------------------------------------------------------

    SYSTEM_PROMPT=$(cat <<'EOF'
You are the Prompt Engineering Review evaluator for:

Modulo 4 - Ollama Model Serving with Kubernetes, HPA and Reliability

Evaluate ONLY the learner's prompt-engineering process.

============================================================
EVIDENCE SOURCE
============================================================

The learner prompt history is the ONLY evidence used to award
prompt-engineering marks.

The learner prompt history is supplied as chatlog.txt.

strict_md.txt, final_rubrics.txt, and output_format.txt are
evaluator reference documents only.

NEVER treat content from those reference documents as something
the learner wrote or demonstrated.

Do not infer evidence that is not explicitly present in the
learner prompt history.

============================================================
DO NOT EVALUATE IMPLEMENTATION QUALITY
============================================================

Do not score:

- shell scripts
- router configuration
- switch configuration
- technical implementation
- incident files
- evidence files
- JSON files
- final technical correctness

The purpose of this evaluation is prompt engineering.

Solution traceability may only be scored when the learner's
prompt history explicitly demonstrates the required traceability.

============================================================
INDEPENDENT SCORING
============================================================

Evaluate each testcase independently.

Missing evidence for one component must not automatically
zero the complete testcase.

A single-shot prompt may receive marks for applicable criteria
such as:

- understanding
- clarity
- completeness
- constraints
- technical requirements

Do not award iteration or collaboration marks unless the
learner prompt history explicitly demonstrates them.

============================================================
MODULO 4 TESTCASES
============================================================

Requirement Understanding and Architecture Planning = 10
Prompt Quality for Build, Deployment and Debugging = 10
Verification and Validation Strategy = 10

Maximum total = 30.

============================================================
DESCRIPTION
============================================================

Every testcase description MUST contain:

Observed Evidence:
Reason for Score:
Missing Evidence:

Observed Evidence must be based only on the learner prompt
history.

Reason for Score must explain the awarded score.

Missing Evidence must identify unsupported criteria.

============================================================
OUTPUT
============================================================

Return ONLY valid JSON.

Do not use Markdown.

Do not use ```json fences.

Do not put any explanation outside the JSON object.

Use the structure specified in output_format.txt.
EOF
)

    # --------------------------------------------------------
    # User prompt
    # --------------------------------------------------------

    USER_PROMPT=$(cat <<EOF
============================================================
LEARNER PROMPT HISTORY
============================================================

IMPORTANT:
This is the ONLY evidence that may be used to award marks.

$CHATLOG_CONTENT


============================================================
MANDATORY EVALUATOR RULES
============================================================

Reference material only.
Do NOT treat this as learner evidence.

$STRICT_CONTENT


============================================================
MODULO 4 RUBRIC
============================================================

Reference material only.
Do NOT treat this as learner evidence.

$RUBRICS_CONTENT


============================================================
REQUIRED OUTPUT FORMAT
============================================================

Reference material only.

$FORMAT_CONTENT


============================================================
TASK
============================================================

Evaluate the learner prompt history for Modulo 4.

Return exactly 3 testcases:

Requirement Understanding and Architecture Planning = 10
Prompt Quality for Build, Deployment and Debugging = 10
Verification and Validation Strategy = 10

Maximum total = 30.

Every testcase description must contain:

Observed Evidence:
Reason for Score:
Missing Evidence:

Return ONLY valid JSON.
EOF
)

    # --------------------------------------------------------
    # Build Gateway request
    # --------------------------------------------------------

    PAYLOAD="$(
        jq -n \
            --arg model \
                "global.anthropic.claude-haiku-4-5-20251001-v1:0" \
            --arg system "$SYSTEM_PROMPT" \
            --arg user "$USER_PROMPT" \
            '{
                model: $model,
                temperature: 0,
                messages: [
                    {
                        role: "system",
                        content: $system
                    },
                    {
                        role: "user",
                        content: $user
                    }
                ]
            }'
    )"

    # --------------------------------------------------------
    # Call LLM Gateway
    # --------------------------------------------------------

    HTTP_RESPONSE="$(
        curl -sS \
            --connect-timeout 15 \
            --max-time 180 \
            -w '\n%{http_code}' \
            -X POST \
            "https://llmgateway-lms.tekstac.com/chat/completions" \
            -H "Authorization: Bearer $HAIKU_KEY" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            2>/dev/null
    )"

    HTTP_CODE="$(
        printf '%s\n' "$HTTP_RESPONSE" |
        tail -n 1
    )"

    RESPONSE_BODY="$(
        printf '%s\n' "$HTTP_RESPONSE" |
        sed '$d'
    )"

    # --------------------------------------------------------
    # Preserve raw Gateway response
    # --------------------------------------------------------

    printf '%s\n' "$RESPONSE_BODY" > "$AI_RAW"

    if [ "$HTTP_CODE" != "200" ]; then

        ai_failure \
            "LLM Gateway returned HTTP status $HTTP_CODE."

    elif ! printf '%s\n' "$RESPONSE_BODY" |
        jq empty >/dev/null 2>&1; then

        ai_failure \
            "LLM Gateway returned invalid JSON."

    else

        # ----------------------------------------------------
        # Extract assistant content
        # ----------------------------------------------------

        AI_CONTENT="$(
            printf '%s\n' "$RESPONSE_BODY" |
            jq -r '.choices[0].message.content // empty'
        )"

        if [ -z "$AI_CONTENT" ]; then

            ai_failure \
                "LLM Gateway returned no assistant content."

        else

            # ------------------------------------------------
            # Remove Markdown code fences
            # ------------------------------------------------

            CLEAN_CONTENT="$(
                printf '%s\n' "$AI_CONTENT" |
                sed \
                    -e '/^[[:space:]]*```json[[:space:]]*$/d' \
                    -e '/^[[:space:]]*```[[:space:]]*$/d'
            )"

            # ------------------------------------------------
            # Validate JSON
            # ------------------------------------------------

            if ! printf '%s\n' "$CLEAN_CONTENT" |
                jq empty >/dev/null 2>&1; then

                ai_failure \
                    "AI assistant content was not valid JSON."

            # ------------------------------------------------
            # Validate top-level structure
            # ------------------------------------------------

            elif ! printf '%s\n' "$CLEAN_CONTENT" |
                jq -e '
                    .expertise.name == "Prompt Engineering Review"
                    and
                    (.expertise.testcases.testcase | type == "array")
                    and
                    (.expertise.testcases.testcase | length == 3)
                ' >/dev/null 2>&1; then

                ai_failure \
                    "AI response did not contain the required Prompt Engineering Review structure."

            else

                EXPECTED_NAMES='[
                    "Requirement Understanding and Architecture Planning",
                    "Prompt Quality for Build, Deployment and Debugging",
                    "Verification and Validation Strategy"
                ]'

                # --------------------------------------------
                # Validate testcase names
                # --------------------------------------------

                if ! printf '%s\n' "$CLEAN_CONTENT" |
                    jq -e \
                    --argjson expected "$EXPECTED_NAMES" '
                        [
                            .expertise.testcases.testcase[].name
                        ] == $expected
                    ' >/dev/null 2>&1; then

                    ai_failure \
                        "AI testcase names do not match the Modulo 4 rubric."

                # --------------------------------------------
                # Validate maximum marks
                # --------------------------------------------

                elif ! printf '%s\n' "$CLEAN_CONTENT" |
                    jq -e '
                        [
                            .expertise.testcases.testcase[].maxmark
                            | tonumber
                        ] == [10, 10, 10]
                    ' >/dev/null 2>&1; then

                    ai_failure \
                        "AI testcase maximum marks do not match 4,4,3,3,3,3."

                # --------------------------------------------
                # Validate score range
                # --------------------------------------------

                elif ! printf '%s\n' "$CLEAN_CONTENT" |
                    jq -e '
                        all(
                            .expertise.testcases.testcase[];
                            (.score | tonumber) >= 0
                            and
                            (.score | tonumber)
                            <=
                            (.maxmark | tonumber)
                        )
                    ' >/dev/null 2>&1; then

                    ai_failure \
                        "AI testcase score is outside its allowed range."

                # --------------------------------------------
                # Validate description sections
                # --------------------------------------------

                elif ! printf '%s\n' "$CLEAN_CONTENT" |
                    jq -e '
                        all(
                            .expertise.testcases.testcase[];
                            (.description | contains("Observed Evidence:"))
                            and
                            (.description | contains("Reason for Score:"))
                            and
                            (.description | contains("Missing Evidence:"))
                        )
                    ' >/dev/null 2>&1; then

                    ai_failure \
                        "AI testcase descriptions do not contain the required evidence sections."

                # --------------------------------------------
                # Validate total maximum = 20
                # --------------------------------------------

                elif ! printf '%s\n' "$CLEAN_CONTENT" |
                    jq -e '
                        (
                            [
                                .expertise.testcases.testcase[].maxmark
                                | tonumber
                            ] | add
                        ) == 30
                    ' >/dev/null 2>&1; then

                    ai_failure \
                        "AI maximum score is not 20."

                else

                    # ----------------------------------------
                    # Normalize output
                    # ----------------------------------------

                    printf '%s\n' "$CLEAN_CONTENT" |
                    jq '
                        .expertise.name =
                            "Prompt Engineering Review"

                        |

                        .expertise.testcases.testcase |=
                        map(
                            .maxmark =
                                (.maxmark | tonumber | tostring)

                            |

                            .score =
                                (.score | tonumber | tostring)

                            |

                            .status =
                                (
                                    if
                                        (.score | tonumber)
                                        ==
                                        (.maxmark | tonumber)
                                    then
                                        "pass"
                                    else
                                        "fail"
                                    end
                                )

                            |

                            .failmessage =
                                (
                                    if
                                        (.score | tonumber)
                                        ==
                                        (.maxmark | tonumber)
                                    then
                                        ""
                                    else
                                        (.failmessage // "")
                                    end
                                )
                        )
                    ' > "$AI_OUTPUT"

                fi

            fi

        fi

    fi

fi

# ============================================================
# Final AI output safety check
# ============================================================

if [ ! -s "$AI_OUTPUT" ] ||
   ! jq empty "$AI_OUTPUT" >/dev/null 2>&1; then

    ai_failure \
        "Final Prompt Engineering Review output is invalid."

fi

if ! jq -e '
    .expertise.name == "Prompt Engineering Review"
    and
    (.expertise.testcases.testcase | type == "array")
    and
    (.expertise.testcases.testcase | length == 3)
' "$AI_OUTPUT" >/dev/null 2>&1; then

    ai_failure \
        "Final Prompt Engineering Review output does not contain 3 testcases."

fi

# ============================================================
# STANDARD TECHNICAL EVALUATION - 70 MARKS
#
# IMPORTANT:
# We are still inside:
#
#   /opt/Test/modulo4
#
# because eval.sh expects the learner project as its current
# working directory.
# ============================================================

EVAL_SCRIPT="$SCRIPT_DIR/eval.sh"

if [ ! -f "$EVAL_SCRIPT" ]; then

    failure_response \
        "eval.sh not found: $EVAL_SCRIPT"

    exit 1

fi

# ------------------------------------------------------------
# Load technical evaluator
# ------------------------------------------------------------

# shellcheck disable=SC1090
source "$EVAL_SCRIPT"

if ! declare -F evaluate_project >/dev/null 2>&1; then

    failure_response \
        "evaluate_project() was not found in eval.sh"

    exit 1

fi

# ============================================================
# Run technical evaluator
# ============================================================

evaluate_project "$ACTIVITY_ID" > "$EVAL_RAW"

EVAL_STATUS=$?

# ============================================================
# Extract technical reportData
# ============================================================

if [ -s "$EVAL_RAW" ]; then

    REPORT_JSON="$(
        sed -n \
            's/.*<reportData>\(.*\)<\/reportData>.*/\1/p' \
            "$EVAL_RAW" |
        tail -n 1
    )"

    if [ -n "$REPORT_JSON" ]; then

        printf '%s\n' "$REPORT_JSON" > "$EVAL_OUTPUT"

    else

        cp "$EVAL_RAW" "$EVAL_OUTPUT"

    fi

else

    cat > "$EVAL_OUTPUT" <<'EOF'
{
  "evaluationdetails": {
    "evaluationbreakup": [],
    "consolidatedtestcase": {
      "totaltestcases": "10",
      "passedtestcase": "0",
      "failedtestcase": "10"
    }
  }
}
EOF

fi

# ============================================================
# Validate technical JSON
# ============================================================

if ! jq empty "$EVAL_OUTPUT" >/dev/null 2>&1; then

    echo "ERROR: eval.sh did not produce valid JSON." >&2
    echo "Raw technical evaluator output:" >&2
    cat "$EVAL_RAW" >&2

    exit 1

fi

# ============================================================
# Combine AI + technical evaluation
#
# output1.json = Prompt Engineering Review /20
# output2.json = Technical Evaluation /80
# ============================================================

jq -s '.' \
    "$AI_OUTPUT" \
    "$EVAL_OUTPUT" \
    > "$RESULTS_OUTPUT"

if [ $? -ne 0 ] ||
   ! jq empty "$RESULTS_OUTPUT" >/dev/null 2>&1; then

    echo "ERROR: Failed to create valid results.json" >&2
    exit 1

fi

# ============================================================
# Run combine.sh
# ============================================================

COMBINE_SCRIPT="$SCRIPT_DIR/combine.sh"

if [ ! -f "$COMBINE_SCRIPT" ]; then

    echo \
        "ERROR: combine.sh not found: $COMBINE_SCRIPT" \
        >&2

    exit 1

fi

chmod +x "$COMBINE_SCRIPT" 2>/dev/null

(
    cd "$TEST_ROOT" || exit 1
    bash "$COMBINE_SCRIPT"
) > "$REPORT_OUTPUT"

COMBINE_STATUS=$?

# ============================================================
# Final Tekstac response
# ============================================================

if [ "$COMBINE_STATUS" -eq 0 ] &&
   [ -s "$REPORT_OUTPUT" ]; then

    cat "$REPORT_OUTPUT"

else

    cat "$EVAL_RAW"

fi

# ============================================================
# Preserve technical evaluator exit status
# ============================================================

exit "$EVAL_STATUS"