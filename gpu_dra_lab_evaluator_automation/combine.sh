#!/bin/bash

INPUT_FILE="${1:-/opt/Test/results.json}"

echo "<reportData>"

jq '
def to_num:
  if type=="number" then .
  elif type=="string" then (tonumber? // 0)
  else 0
  end;

# Static Review
(
  .[]
  | select(has("expertise"))
  | .expertise
  | .testcases.testcase |=
      map(
        .shortdescription =
          (if (.shortdescription == null or .shortdescription == "")
           then .description
           else .shortdescription
           end)
        |
        .failmessage =
          (if (.status | ascii_downcase) == "pass"
           then ""
           else .failmessage
           end)
      )
) as $expertise |

# Compile / Execute
[
  .[]
  | select(has("evaluationdetails"))
  | .evaluationdetails.evaluationbreakup[]
] as $exec |

($expertise.testcases.testcase | length) as $st_total |
($expertise.testcases.testcase | map(select((.status|ascii_downcase)=="pass")) | length) as $st_pass |
($expertise.testcases.testcase | map(.score|to_num) | add //0) as $st_score |
($expertise.testcases.testcase | map(.maxmark|to_num) | add //0) as $st_max |

($exec | map(.score|to_num) | add //0) as $ex_score |
($exec | map(.maxmark|to_num) | add //0) as $ex_max |
($exec | map(.totaltestcase|to_num) | add //0) as $ex_total |
($exec | map(.testcasepassed|to_num) | add //0) as $ex_pass |

{
  grade: ($st_score + $ex_score),

  evaluationdetails: {

    evaluationbreakup:
      (
        [
          {
            name: "AI Based Evaluation",
            totaltestcase: ($st_total|tostring),
            testcasepassed: ($st_pass|tostring),
            maxmark: ($st_max|tostring),
            score: ($st_score|tostring),
            status:
			(
				if $st_score == $st_max then
					"Pass"
				elif $st_score > 0 then
					"Partial"
				else
					"Fail"
				end
			),
            feedback: "",
            expertises: {
              expertise: $expertise
            }
          }
        ] + $exec
      ),

    consolidatedtestcase: {
      totaltestcases: (($st_total + $ex_total)|tostring),
      passedtestcase: (($st_pass + $ex_pass)|tostring),
      failedtestcase: ((($st_total + $ex_total) - ($st_pass + $ex_pass))|tostring)
    }
  }
}
' "$INPUT_FILE"

echo "</reportData>"