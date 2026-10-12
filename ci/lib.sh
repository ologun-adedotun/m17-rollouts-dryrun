# Helpers shared by the experiment scripts.
IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app
K6=ghcr.io/${GITHUB_REPOSITORY}/maright-k6:v1
APPS=9
H() { echo; echo "=== $* ==="; }
now() { date +%s; }
ts() { date +%H:%M:%S; }
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

installargo() {
  helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.3 \
    -n argocd --create-namespace -f deploy/argocd/values.yaml --wait --timeout 6m >/dev/null
}
refresh() { for a in "$@"; do kubectl annotate application "$a" -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1; done; }
state() { kubectl get application "$1" -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}@{.status.sync.revision}' 2>/dev/null; }
short() { local s; s=$(state "$1"); echo "${s%@*}@$(echo "${s##*@}" | cut -c1-7)"; }
waitapp() {
  local n=$1 s=$2 h=$3 rev=${4:-} to=${5:-300} t0 st
  t0=$(now)
  while :; do
    st=$(state "$n")
    if [[ "$st" == "$s/$h@"* ]] && { [ -z "$rev" ] || [[ "$st" == *"@$rev" ]]; }; then
      echo "$n reached $s/$h after $(( $(now) - t0 ))s"; return 0; fi
    if (( $(now) - t0 > to )); then echo "$n TIMED OUT after ${to}s at ${st:-nothing}"; return 1; fi
    refresh "$n"; sleep 4
  done
}
waitall() {
  local want=$1 to=$2 t0 prev="" cur ok
  t0=$(now)
  while :; do
    cur=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}' 2>/dev/null)
    if [ "$cur" != "$prev" ]; then echo "+$(( $(now) - t0 ))s  $cur"; prev=$cur; fi
    ok=$(echo "$cur" | tr ' ' '\n' | grep -c '=Synced/Healthy$')
    if [ "$ok" -ge "$want" ]; then echo "all $ok Synced/Healthy after $(( $(now) - t0 ))s"; return 0; fi
    if (( $(now) - t0 > to )); then echo "NOT all healthy after ${to}s"; return 1; fi
    sleep 5
  done
}
push() { git add -A; git commit -q -m "$1"; git push -q origin HEAD:main; git rev-parse HEAD; }
revertpush() { git revert --no-edit HEAD >/dev/null; git push -q origin HEAD:main; git rev-parse HEAD; }
setval() { # setval ENV KEY VALUE  (top-level or two-level "image.tag")
  python3 - "$1" "$2" "$3" <<'EOF'
import re, sys
env, key, val = sys.argv[1:]
p = f"deploy/envs/{env}/values.yaml"
s = open(p).read()
if "." in key:
    a, b = key.split(".")
    s = re.sub(rf"(^{a}:\n(?:  .*\n)*?  {b}: ).*", rf"\g<1>{val}", s, count=1, flags=re.M)
else:
    s = re.sub(rf"^{key}: .*", f"{key}: {val}", s, count=1, flags=re.M)
open(p, "w").write(s)
EOF
}
gwsvc() { kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=mission -o jsonpath='{.items[0].metadata.name}'; }
gw() { kubectl port-forward -n envoy-gateway-system "svc/$(gwsvc)" 8081:80 >/dev/null 2>&1 & PF=$!; sleep 4; }
ver() { curl -s -m 5 -H "Host: $1" ${2:+-H "$2"} http://127.0.0.1:8081/ | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("version","?"))
except Exception: print("error")'; }
sample() { # sample HOST N -> counts of versions seen
  local i; for i in $(seq "$2"); do ver "$1" "${3:-}"; done | sort | uniq -c | tr '\n' ' '; echo; }
k6start() { # k6start NAME HOST RATE DURATION
  kubectl delete job "$1" -n load --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create job "$1" -n load --image="$K6" -- k6 run -q -e TARGET="http://$(gwsvc).envoy-gateway-system.svc.cluster.local/" -e HOST="$2" -e RATE="$3" -e DURATION="$4" /scripts/load.js >/dev/null
}
k6wait() {
  kubectl wait --for=condition=complete "job/$1" -n load --timeout="${2:-400s}" >/dev/null || echo "job $1 did not complete"
  echo "$1: $(kubectl logs -n load "job/$1" | grep RESULT)"
}
weights() { kubectl get httproute mission -n "$1" -o jsonpath='{range .spec.rules[*]}[{range .backendRefs[*]}{.name}={.weight} {end}{range .matches[*].headers[*]}{.name}:{.value}{end}] {end}' 2>/dev/null; }
ro() { kubectl get rollout "${RO:-mission}" -n "$1" -o jsonpath='{.status.phase} step={.status.currentStepIndex} {.status.message}' 2>/dev/null; }
# watchro NS SECONDS STOP-REGEX: print each change of rollout phase/step/weights/analysis runs
watchro() {
  local ns=$1 to=$2 stop=$3 t0 prev="" cur
  t0=$(now)
  while :; do
    cur="$(ro "$ns") | $(weights "$ns") | runs: $(kubectl get analysisrun -n "$ns" --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null | tr ' ' '\n' | tail -n 3 | sed 's/^mission-[a-z0-9]*-//' | tr '\n' ' ')"
    if [ "$cur" != "$prev" ]; then echo "+$(( $(now) - t0 ))s  $cur"; prev=$cur; fi
    if [[ "$(ro "$ns")" =~ $stop ]]; then return 0; fi
    if (( $(now) - t0 > to )); then echo "watch ended after ${to}s"; return 1; fi
    sleep 3
  done
}
cat > /tmp/runs.py <<'EOF'
import json, sys
n = int(sys.argv[1])
for r in json.load(sys.stdin)["items"][-n:]:
    st = r.get("status", {})
    parts = []
    for m in st.get("metricResults", []):
        last = (m.get("measurements") or [{}])[-1]
        parts.append("%s=%s last=%s msg=%s" % (m.get("name"), m.get("phase"), str(last.get("value", ""))[:40], (m.get("message") or "")[:120]))
    print(r["metadata"]["name"], st.get("phase"), "|", "; ".join(parts))
EOF
runresults() { kubectl get analysisrun -n "$1" --sort-by=.metadata.creationTimestamp -o json | python3 /tmp/runs.py "${2:-3}"; }