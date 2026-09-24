#!/bin/bash

evaluate_project() {

    local student_id="$1"
    local projectName="modulo4"
    local LOG_PATH="/opt/Test"

    cd "/opt/Test/$projectName" || exit 1

    total_passed=0
    total_failed=0
    final_score=0

    # ============================================================
    # Common Configuration
    # ============================================================

    # Standard lab inference endpoint.
    # Resource names and Ollama model names are NOT fixed.
    GATEWAY_URL="${GATEWAY_URL:-http://localhost:8084}"

    # ============================================================
    # Helper Functions
    # ============================================================

    # Find a Deployment that has at least one available replica.
    find_candidate_deployment() {
        kubectl get deployments -o json 2>/dev/null | python3 - <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)

    for item in data.get("items", []):
        spec = item.get("spec", {})
        status = item.get("status", {})

        replicas = spec.get("replicas", 0) or 0
        available = status.get("availableReplicas", 0) or 0

        if replicas >= 1 and available >= 1:
            print(item["metadata"]["name"])
            sys.exit(0)

except Exception:
    pass
PY
    }

    # Find an HPA that targets an existing Deployment.
    find_candidate_hpa() {
        kubectl get hpa -o json 2>/dev/null | python3 - <<'PY'
import json
import subprocess
import sys

try:
    data = json.load(sys.stdin)

    for item in data.get("items", []):
        target = item.get("spec", {}).get("scaleTargetRef", {})

        if target.get("kind") != "Deployment":
            continue

        name = target.get("name", "")

        if not name:
            continue

        result = subprocess.run(
            ["kubectl", "get", "deployment", name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        if result.returncode == 0:
            print(item["metadata"]["name"])
            sys.exit(0)

except Exception:
    pass
PY
    }

    # ============================================================
    # Discover Student Kubernetes Resources
    # ============================================================

    CANDIDATE_DEPLOYMENT=$(find_candidate_deployment)
    CANDIDATE_HPA=$(find_candidate_hpa)

    # ============================================================
    # TC01 : Verifying Kubernetes Gateway to Ollama Model Runtime Integration
    # ============================================================

    tc1_passed=0
    tc1_score=0
    tc1_status="Fail"
    tc1_obs=""
    tc1_feedback=""

    deployment_name=""
    ollama_url=""
    ollama_model=""

    # Discover a Deployment used by the lab
    deployment_name=$(kubectl get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)

    if [ -n "$deployment_name" ]; then

        # Read OLLAMA_URL from the Deployment
        ollama_url=$(kubectl get deployment "$deployment_name" \
            -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="OLLAMA_URL")]}{.value}{end}' \
            2>/dev/null)

        # Read OLLAMA_MODEL from the Deployment
        ollama_model=$(kubectl get deployment "$deployment_name" \
            -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="OLLAMA_MODEL")]}{.value}{end}' \
            2>/dev/null)

        if [ -n "$ollama_url" ] && [ -n "$ollama_model" ]; then

            # Verify Ollama runtime is reachable on the VM
            ollama_runtime_ok=false

            if curl -s --max-time 5 "${ollama_url}/api/tags" >/dev/null 2>&1; then
                ollama_runtime_ok=true
            fi

            # Verify configured model exists in Ollama
            model_exists=false

            if [ "$ollama_runtime_ok" = true ]; then
                if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$ollama_model"; then
                    model_exists=true
                fi
            fi

            if [ "$ollama_runtime_ok" = true ] && [ "$model_exists" = true ]; then
                tc1_passed=1
                tc1_score=10
                tc1_status="Pass"
                tc1_obs="Deployment '$deployment_name' is configured with OLLAMA_URL='$ollama_url' and OLLAMA_MODEL='$ollama_model'. Ollama runtime is reachable and the configured model exists."
                tc1_feedback="Kubernetes gateway is connected to the Ollama model runtime."
                ((final_score+=10)) 
                ((total_passed++))
            else
                if [ "$ollama_runtime_ok" != true ]; then
                    tc1_obs="Deployment '$deployment_name' contains OLLAMA_URL='$ollama_url' and OLLAMA_MODEL='$ollama_model', but the Ollama runtime could not be reached."
                    tc1_feedback="Verify that Ollama is running and the configured OLLAMA_URL is correct."
                    ((total_failed++))
                else
                    tc1_obs="Deployment '$deployment_name' contains OLLAMA_URL='$ollama_url' and OLLAMA_MODEL='$ollama_model', but the configured model was not found in Ollama."
                    tc1_feedback="Verify that OLLAMA_MODEL matches an available Ollama model."
                    ((total_failed++))
                fi
            fi

        else
            tc1_obs="Deployment '$deployment_name' does not contain both OLLAMA_URL and OLLAMA_MODEL configuration."
            tc1_feedback="Configure the Kubernetes gateway to connect to the Ollama runtime and specify the model."
            ((total_failed++))
        fi

    else
        tc1_obs="No Kubernetes Deployment was found."
        tc1_feedback="Deploy the Ollama gateway application to Kubernetes."
        ((total_failed++))
    fi


    # ============================================================
    # TC02 : Verifying Model Serving Inference Endpoint
    # ============================================================

    tc2_passed=0
    tc2_score=0
    tc2_status="Fail"
    tc2_obs=""
    tc2_feedback=""

    tc2_response=""
    tc2_curl_status=1

    tc2_response=$(curl -sS --max-time 180 \
        -X POST "${GATEWAY_URL}/generate" \
        -H "Content-Type: application/json" \
        -d '{
            "prompt": "Explain Kubernetes in one simple sentence."
        }' 2>/dev/null)

    tc2_curl_status=$?

    tc2_valid_json=false
    tc2_response_found=false
    tc2_model_found=false

    if [ "$tc2_curl_status" -eq 0 ] && [ -n "$tc2_response" ]; then

        if echo "$tc2_response" | python3 -m json.tool >/dev/null 2>&1; then
            tc2_valid_json=true
        fi

        if python3 - "$tc2_response" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
    response = data.get("response", "")

    if isinstance(response, str) and len(response.strip()) > 0:
        sys.exit(0)

except Exception:
    pass

sys.exit(1)
PY
        then
            tc2_response_found=true
        fi

        if python3 - "$tc2_response" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
    model = data.get("model", "")

    if isinstance(model, str) and model.strip():
        sys.exit(0)

except Exception:
    pass

sys.exit(1)
PY
        then
            tc2_model_found=true
        fi
    fi

    tc2_obs="Endpoint: ${GATEWAY_URL}/generate, JSON Valid: $tc2_valid_json, Response Found: $tc2_response_found, Model Metadata Found: $tc2_model_found."

    if [ "$tc2_valid_json" = true ] && \
       [ "$tc2_response_found" = true ] && \
       [ "$tc2_model_found" = true ]; then

        tc2_passed=1
        tc2_score=10
        tc2_status="Success"
        tc2_feedback="Model-serving endpoint successfully processed an inference request and returned a valid model response."
        ((final_score+=10))
        ((total_passed++))
    else
        tc2_score=0
        tc2_status="Fail"
        tc2_feedback="Model-serving endpoint did not return a valid inference response."
        ((total_failed++))
    fi


    # ============================================================
    # TC03 : Verifying Health and Readiness Endpoints
    # ============================================================

    tc3_passed=0
    tc3_score=0
    tc3_status="Fail"
    tc3_obs=""
    tc3_feedback=""

    health_response=""
    ready_response=""

    health_status=1
    ready_status=1

    health_response=$(curl -sS --max-time 20 \
        -w "\n%{http_code}" \
        "${GATEWAY_URL}/health" 2>/dev/null)

    health_code=$(echo "$health_response" | tail -1)
    health_body=$(echo "$health_response" | sed '$d')

    ready_response=$(curl -sS --max-time 20 \
        -w "\n%{http_code}" \
        "${GATEWAY_URL}/ready" 2>/dev/null)

    ready_code=$(echo "$ready_response" | tail -1)
    ready_body=$(echo "$ready_response" | sed '$d')

    health_ok=false
    ready_ok=false

    if [ "$health_code" = "200" ]; then
        if echo "$health_body" | grep -Eiq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
            health_ok=true
        fi
    fi

    if [ "$ready_code" = "200" ]; then
        if echo "$ready_body" | grep -Eiq '"status"[[:space:]]*:[[:space:]]*"ready"'; then
            ready_ok=true
        fi
    fi

    tc3_obs="Health HTTP: ${health_code:-N/A}, Health Valid: $health_ok, Readiness HTTP: ${ready_code:-N/A}, Readiness Valid: $ready_ok."

    if [ "$health_ok" = true ] && [ "$ready_ok" = true ]; then
        tc3_passed=1
        tc3_score=10
        tc3_status="Success"
        tc3_feedback="Health and readiness endpoints are available and report the application as healthy and ready."
        ((final_score+=10))
        ((total_passed++))
    else
        tc3_score=0
        tc3_status="Fail"
        tc3_feedback="Health or readiness validation failed."
        ((total_failed++))
    fi


    # ============================================================
    # TC04 : Verifying Kubernetes Deployment, Pods and Service
    # ============================================================

    tc4_passed=0
    tc4_score=0
    tc4_status="Fail"
    tc4_obs=""
    tc4_feedback=""

    deployment_ok=false
    pod_ok=false
    service_ok=false
    endpoint_ok=false

    deployment_name="${CANDIDATE_DEPLOYMENT:-}"

    if [ -n "$deployment_name" ]; then

        deployment_json=$(kubectl get deployment "$deployment_name" -o json 2>/dev/null)

        if [ -n "$deployment_json" ]; then

            desired_replicas=$(echo "$deployment_json" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("spec",{}).get("replicas",0))
except:
    print(0)
')

            available_replicas=$(echo "$deployment_json" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("status",{}).get("availableReplicas",0) or 0)
except:
    print(0)
')

            if [ "${desired_replicas:-0}" -ge 1 ] && \
               [ "${available_replicas:-0}" -ge 1 ]; then
                deployment_ok=true
            fi

            # Find pods using the Deployment selector.
            selector=$(echo "$deployment_json" | python3 -c '
import json,sys
try:
    labels=json.load(sys.stdin).get("spec",{}).get("selector",{}).get("matchLabels",{})
    print(",".join([f"{k}={v}" for k,v in labels.items()]))
except:
    print("")
')

            if [ -n "$selector" ]; then
                ready_pods=$(kubectl get pods -l "$selector" \
                    -o json 2>/dev/null | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
    count=0
    for p in data.get("items",[]):
        for c in p.get("status",{}).get("conditions",[]):
            if c.get("type")=="Ready" and c.get("status")=="True":
                count += 1
                break
    print(count)
except:
    print(0)
')

                if [ "${ready_pods:-0}" -ge 1 ]; then
                    pod_ok=true
                fi

                # Find Service selecting the same pod labels.
                services_json=$(kubectl get services -o json 2>/dev/null)

                service_name=$(python3 - "$services_json" "$selector" <<'PY'
import json
import sys

try:
    data=json.loads(sys.argv[1])
    selector_string=sys.argv[2]

    wanted={}
    for part in selector_string.split(","):
        if "=" in part:
            k,v=part.split("=",1)
            wanted[k]=v

    for svc in data.get("items",[]):
        selector=svc.get("spec",{}).get("selector",{})

        if selector and all(selector.get(k)==v for k,v in wanted.items()):
            print(svc["metadata"]["name"])
            sys.exit(0)

except Exception:
    pass
PY
)

                if [ -n "$service_name" ]; then
                    service_ok=true

                    endpoint_count=$(kubectl get endpoints "$service_name" \
                        -o json 2>/dev/null | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
    count=0
    for subset in data.get("subsets",[]):
        count += len(subset.get("addresses",[]))
    print(count)
except:
    print(0)
')

                    if [ "${endpoint_count:-0}" -ge 1 ]; then
                        endpoint_ok=true
                    fi
                fi
            fi
        fi
    fi

    tc4_obs="Deployment discovered: ${deployment_name:-None}, Deployment Ready: $deployment_ok, Ready Pods: $pod_ok, Matching Service: $service_ok, Service Endpoints: $endpoint_ok."

    if [ "$deployment_ok" = true ] && \
       [ "$pod_ok" = true ] && \
       [ "$service_ok" = true ] && \
       [ "$endpoint_ok" = true ]; then

        tc4_passed=1
        tc4_score=10
        tc4_status="Success"
        tc4_feedback="Kubernetes Deployment, running Pod, Service selector, and active Service endpoint were verified dynamically without requiring fixed resource names."
        ((final_score+=10))
        ((total_passed++))
    else
        tc4_score=0
        tc4_status="Fail"
        tc4_feedback="A valid Deployment, ready Pod, matching Service, or Service endpoint could not be verified."
        ((total_failed++))
    fi


    # ============================================================
    # TC05 : Verifying HPA Configuration
    # ============================================================

    tc5_passed=0
    tc5_score=0
    tc5_status="Fail"
    tc5_obs=""
    tc5_feedback=""

    hpa_ok=false
    target_ok=false
    min_ok=false
    max_ok=false
    metric_ok=false

    hpa_name="${CANDIDATE_HPA:-}"

    if [ -n "$hpa_name" ]; then

        hpa_json=$(kubectl get hpa "$hpa_name" -o json 2>/dev/null)

        if [ -n "$hpa_json" ]; then

            target_kind=$(echo "$hpa_json" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("spec",{}).get("scaleTargetRef",{}).get("kind",""))
except:
    print("")
')

            target_name=$(echo "$hpa_json" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("spec",{}).get("scaleTargetRef",{}).get("name",""))
except:
    print("")
')

            min_replicas=$(echo "$hpa_json" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("spec",{}).get("minReplicas",1))
except:
    print(0)
')

            max_replicas=$(echo "$hpa_json" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin).get("spec",{}).get("maxReplicas",0))
except:
    print(0)
')

            if [ "$target_kind" = "Deployment" ] && [ -n "$target_name" ]; then
                if kubectl get deployment "$target_name" >/dev/null 2>&1; then
                    target_ok=true
                fi
            fi

            if [ "${min_replicas:-0}" -ge 1 ]; then
                min_ok=true
            fi

            if [ "${max_replicas:-0}" -gt "${min_replicas:-0}" ]; then
                max_ok=true
            fi

            metric_count=$(echo "$hpa_json" | python3 -c '
import json,sys
try:
    metrics=json.load(sys.stdin).get("spec",{}).get("metrics",[])
    count=0
    for m in metrics:
        if m.get("type") in ["Resource","Pods","Object","External"]:
            count += 1
    print(count)
except:
    print(0)
')

            if [ "${metric_count:-0}" -ge 1 ]; then
                metric_ok=true
            fi

            if [ "$target_ok" = true ] && \
               [ "$min_ok" = true ] && \
               [ "$max_ok" = true ] && \
               [ "$metric_ok" = true ]; then
                hpa_ok=true
            fi
        fi
    fi

    tc5_obs="HPA discovered: ${hpa_name:-None}, Target Deployment: ${target_ok}, Min Replicas Valid: $min_ok, Max Replicas Valid: $max_ok, Scaling Metric Present: $metric_ok."

    if [ "$hpa_ok" = true ]; then
        tc5_passed=1
        tc5_score=10
        tc5_status="Success"
        tc5_feedback="A valid HPA was dynamically discovered and verified with a Deployment target, valid replica range, and scaling metric."
        ((final_score+=10))
        ((total_passed++))
    else
        tc5_score=0
        tc5_status="Fail"
        tc5_feedback="A valid Horizontal Pod Autoscaler configuration could not be verified."
        ((total_failed++))
    fi


    # ============================================================
    # TC06 : Verifying HPA Autoscaling Configuration
    # ============================================================

    tc6_passed=0
    tc6_score=0
    tc6_status="Fail"
    tc6_obs=""
    tc6_feedback=""

    final_hpa_name=""
    hpa_target_deployment=""
    hpa_min_replicas=0
    hpa_max_replicas=0
    hpa_cpu_target=""
    hpa_metric_found=false
    hpa_target_found=false

    # ------------------------------------------------------------
    # Discover an HPA dynamically
    # Student can use any HPA name
    # ------------------------------------------------------------

    final_hpa_name=$(kubectl get hpa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | head -1)

    if [ -n "$final_hpa_name" ]; then

        # Get HPA target Deployment
        hpa_target_deployment=$(kubectl get hpa "$final_hpa_name" \
            -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)

        # Get replica configuration
        hpa_min_replicas=$(kubectl get hpa "$final_hpa_name" \
            -o jsonpath='{.spec.minReplicas}' 2>/dev/null)

        hpa_max_replicas=$(kubectl get hpa "$final_hpa_name" \
            -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)

        # Check CPU target if configured
        hpa_cpu_target=$(kubectl get hpa "$final_hpa_name" \
            -o jsonpath='{range .spec.metrics[*]}{.resource.target.averageUtilization}{"\n"}{end}' \
            2>/dev/null | head -1)

        # Check whether any scaling metric exists
        metric_count=$(kubectl get hpa "$final_hpa_name" \
            -o jsonpath='{.spec.metrics[*].type}' 2>/dev/null | wc -w)

        if [ "${metric_count:-0}" -gt 0 ]; then
            hpa_metric_found=true
        fi

        # Verify target Deployment exists
        if [ -n "$hpa_target_deployment" ]; then
            if kubectl get deployment "$hpa_target_deployment" >/dev/null 2>&1; then
                hpa_target_found=true
            fi
        fi

    fi

    tc6_obs="HPA: ${final_hpa_name:-None}, Target Deployment: ${hpa_target_deployment:-None}, Min Replicas: ${hpa_min_replicas:-0}, Max Replicas: ${hpa_max_replicas:-0}, CPU Target: ${hpa_cpu_target:-Not Configured}, Scaling Metric Found: $hpa_metric_found, Target Deployment Found: $hpa_target_found."

    # ------------------------------------------------------------
    # Evaluate HPA configuration
    #
    # Pass conditions:
    # 1. HPA exists
    # 2. HPA targets an existing Deployment
    # 3. Minimum replicas >= 1
    # 4. Maximum replicas > minimum replicas
    # 5. At least one scaling metric is configured
    # ------------------------------------------------------------

    if [ -n "$final_hpa_name" ] && \
       [ "$hpa_target_found" = true ] && \
       [ "${hpa_min_replicas:-0}" -ge 1 ] && \
       [ "${hpa_max_replicas:-0}" -gt "${hpa_min_replicas:-0}" ] && \
       [ "$hpa_metric_found" = true ]; then

        tc6_passed=1
        tc6_score=10
        tc6_status="Success"

        tc6_feedback="Kubernetes HPA autoscaling is configured and targets an existing Deployment with valid replica limits and a scaling metric."

        ((final_score+=10))
        ((total_passed++))

    else

        tc6_score=0
        tc6_status="Fail"

        if [ -z "$final_hpa_name" ]; then
            tc6_feedback="No Kubernetes HPA configuration was found."
        elif [ "$hpa_target_found" != true ]; then
            tc6_feedback="HPA was found, but its target Deployment does not exist."
        elif [ "${hpa_min_replicas:-0}" -lt 1 ]; then
            tc6_feedback="HPA minimum replica configuration is invalid."
        elif [ "${hpa_max_replicas:-0}" -le "${hpa_min_replicas:-0}" ]; then
            tc6_feedback="HPA maximum replicas must be greater than minimum replicas."
        elif [ "$hpa_metric_found" != true ]; then
            tc6_feedback="HPA exists but no scaling metric is configured."
        else
            tc6_feedback="HPA autoscaling configuration could not be validated."
        fi

        ((total_failed++))
    fi


    # ============================================================
    # TC07 : Verifying Kubernetes Self-Healing
    # ============================================================

    tc7_passed=0
    tc7_score=0
    tc7_status="Fail"
    tc7_obs=""
    tc7_feedback=""

    self_healing_ok=false
    old_pod=""
    new_pod=""

    if [ -n "$deployment_name" ]; then

        deployment_json=$(kubectl get deployment "$deployment_name" -o json 2>/dev/null)

        selector=$(echo "$deployment_json" | python3 -c '
import json,sys
try:
    labels=json.load(sys.stdin).get("spec",{}).get("selector",{}).get("matchLabels",{})
    print(",".join([f"{k}={v}" for k,v in labels.items()]))
except:
    print("")
')

        if [ -n "$selector" ]; then

            old_pod=$(kubectl get pods -l "$selector" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)

            if [ -n "$old_pod" ]; then

                kubectl delete pod "$old_pod" --wait=false >/dev/null 2>&1

                # Wait for a replacement pod.
                for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do

                    sleep 5

                    pod_list=$(kubectl get pods -l "$selector" \
                        -o json 2>/dev/null)

                    new_pod=$(python3 - "$pod_list" "$old_pod" <<'PY'
import json
import sys

try:
    data=json.loads(sys.argv[1])
    old=sys.argv[2]

    for p in data.get("items",[]):
        name=p.get("metadata",{}).get("name","")

        if name == old:
            continue

        conditions=p.get("status",{}).get("conditions",[])

        ready=False

        for c in conditions:
            if c.get("type")=="Ready" and c.get("status")=="True":
                ready=True

        if ready:
            print(name)
            sys.exit(0)

except Exception:
    pass
PY
)

                    if [ -n "$new_pod" ]; then
                        self_healing_ok=true
                        break
                    fi
                done
            fi
        fi
    fi

    tc7_obs="Deployment: ${deployment_name:-None}, Deleted Pod: ${old_pod:-None}, Replacement Ready Pod: ${new_pod:-None}, Self-Healing Verified: $self_healing_ok."

    if [ "$self_healing_ok" = true ]; then
        tc7_passed=1
        tc7_score=10
        tc7_status="Success"
        tc7_feedback="The application Deployment automatically recreated a deleted Pod and the replacement Pod reached Ready state."
        ((final_score+=10))
        ((total_passed++))
    else
        tc7_score=0
        tc7_status="Fail"
        tc7_feedback="Kubernetes self-healing could not be verified after Pod deletion."
        ((total_failed++))
    fi

    # ============================================================
    # FINAL SCORE & REPORT DATA
    # ============================================================

    local formatted_grade
    formatted_grade="$(printf "%.2f" "$final_score")"

    local reportData
    reportData=$(cat <<EOF | jq -c '.'
{
  "evaluationdetails": {
    "evaluationbreakup": [
      {
        "name": "Gateway and Ollama integration",
        "totaltestcase": 1,
        "testcasepassed": $tc1_passed,
        "maxmark": 10,
        "score": $tc1_score,
        "status": "$tc1_status",
        "feedback": "$tc1_feedback",
        "expertises": {
          "expertise": {
            "name": "Model Runtime",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Gateway and Ollama integration",
                  "description": "$tc1_obs",
                  "shortdescription": "$tc1_feedback",
                  "maxmark": 10,
                  "score": $tc1_score,
                  "status": "$tc1_status"
                }
              ]
            }
          }
        }
      },
      {
        "name": "Verifying Model Serving Inference Endpoint",
        "totaltestcase": 1,
        "testcasepassed": $tc2_passed,
        "maxmark": 10,
        "score": $tc2_score,
        "status": "$tc2_status",
        "feedback": "$tc2_feedback",
        "expertises": {
          "expertise": {
            "name": "Model Serving",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Verifying Model Serving Inference Endpoint",
                  "description": "$tc2_obs",
                  "shortdescription": "$tc2_feedback",
                  "maxmark": 10,
                  "score": $tc2_score,
                  "status": "$tc2_status"
                }
              ]
            }
          }
        }
      },
      {
        "name": "Verifying Health and Readiness Endpoints",
        "totaltestcase": 1,
        "testcasepassed": $tc3_passed,
        "maxmark": 10,
        "score": $tc3_score,
        "status": "$tc3_status",
        "feedback": "$tc3_feedback",
        "expertises": {
          "expertise": {
            "name": "Application Health",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Verifying Health and Readiness Endpoints",
                  "description": "$tc3_obs",
                  "shortdescription": "$tc3_feedback",
                  "maxmark": 10,
                  "score": $tc3_score,
                  "status": "$tc3_status"
                }
              ]
            }
          }
        }
      },
      {
        "name": "Verifying Kubernetes Deployment, Pods and Service",
        "totaltestcase": 1,
        "testcasepassed": $tc4_passed,
        "maxmark": 10,
        "score": $tc4_score,
        "status": "$tc4_status",
        "feedback": "$tc4_feedback",
        "expertises": {
          "expertise": {
            "name": "Kubernetes Model Serving Infrastructure",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Verifying Kubernetes Deployment, Pods and Service",
                  "description": "$tc4_obs",
                  "shortdescription": "$tc4_feedback",
                  "maxmark": 10,
                  "score": $tc4_score,
                  "status": "$tc4_status"
                }
              ]
            }
          }
        }
      },
      {
        "name": "Verifying HPA Configuration",
        "totaltestcase": 1,
        "testcasepassed": $tc5_passed,
        "maxmark": 10,
        "score": $tc5_score,
        "status": "$tc5_status",
        "feedback": "$tc5_feedback",
        "expertises": {
          "expertise": {
            "name": "Autoscaling Configuration",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Verifying HPA Configuration",
                  "description": "$tc5_obs",
                  "shortdescription": "$tc5_feedback",
                  "maxmark": 10,
                  "score": $tc5_score,
                  "status": "$tc5_status"
                }
              ]
            }
          }
        }
      },
      {
        "name": "Verifying Autoscaling Under Simulated Inference Load",
        "totaltestcase": 1,
        "testcasepassed": $tc6_passed,
        "maxmark": 10,
        "score": $tc6_score,
        "status": "$tc6_status",
        "feedback": "$tc6_feedback",
        "expertises": {
          "expertise": {
            "name": "Autoscaling Operations",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Verifying Autoscaling Under Simulated Inference Load",
                  "description": "$tc6_obs",
                  "shortdescription": "$tc6_feedback",
                  "maxmark": 10,
                  "score": $tc6_score,
                  "status": "$tc6_status"
                }
              ]
            }
          }
        }
      },
      {
        "name": "Verifying Kubernetes Self-Healing",
        "totaltestcase": 1,
        "testcasepassed": $tc7_passed,
        "maxmark": 10,
        "score": $tc7_score,
        "status": "$tc7_status",
        "feedback": "$tc7_feedback",
        "expertises": {
          "expertise": {
            "name": "Reliability Management",
            "testcases": {
              "testcase": [
                {
                  "visible": "yes",
                  "name": "Verifying Kubernetes Self-Healing",
                  "description": "$tc7_obs",
                  "shortdescription": "$tc7_feedback",
                  "maxmark": 10,
                  "score": $tc7_score,
                  "status": "$tc7_status"
                }
              ]
            }
          }
        }
      }
    ],
    "consolidatedtestcase": {
      "totaltestcases": 7,
      "passedtestcase": $total_passed,
      "failedtestcase": $total_failed
    }
  }
}
EOF
)

    echo "Grade:=>>$formatted_grade <reportData>$reportData</reportData>"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    evaluate_project "$@"
fi