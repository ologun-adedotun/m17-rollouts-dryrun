#!/usr/bin/env bash
# Run 5: the header route with a ConfigMap permission for the plugin.
set -uo pipefail
source ci/lib.sh

H "S. Platform from Git"
installargo
kubectl create namespace load >/dev/null
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall $APPS 900 | tail -n 1
for e in staging production; do setval $e workload rollout; done
REV=$(push "Both environments as Rollouts")
refresh mission-staging mission-production
waitapp mission-staging Synced Healthy "$REV" 300; waitapp mission-production Synced Healthy "$REV" 300

headerwatch() { # NS NAME HOST: during step 1, look at the route and try the header, for 20 s
  local i
  for i in 1 2 3 4; do
    echo "$(ts) $(RO=$2 ro "$1" | cut -c1-40) | $(kubectl get httproute "$2" -n "$1" -o jsonpath='{range .spec.rules[*]}[{range .backendRefs[*]}{.name}={.weight} {end}{range .matches[*].headers[*]}{.name}:{.value}{end}] {end}')"
    gw; echo "   header -> $(sample "$3" 6 'X-Canary: yes')   no header -> $(sample "$3" 6)"; kill $PF
    sleep 2
  done
}

H "H0. Can the controller manage ConfigMaps?"
for ns in sandbox staging; do echo "$ns: get=$(kubectl auth can-i get configmaps -n $ns --as=system:serviceaccount:argo-rollouts:argo-rollouts) create=$(kubectl auth can-i create configmaps -n $ns --as=system:serviceaccount:argo-rollouts:argo-rollouts) update=$(kubectl auth can-i update configmaps -n $ns --as=system:serviceaccount:argo-rollouts:argo-rollouts)"; done
H "H1. Header route outside Argo CD (sandbox namespace, same chart)"
kubectl create namespace sandbox >/dev/null
kubectl label namespace sandbox mission-routes=allowed >/dev/null
sb() { helm template sb charts/maright-app -n sandbox -f deploy/envs/staging/values.yaml --set workload=rollout \
  --set autoscaling.enabled=false --set 'route.hostnames[0]=sandbox.mission.local' --set image.tag="$1" \
  --set rollout.testerSeconds=40 | kubectl apply -n sandbox -f - >/dev/null; }
sb v2.2.0
RO=sb watchro sandbox 180 '^Healthy' | tail -n 1
k6start sbload sandbox.mission.local 20 200s
sb v2.2.1
RO=sb watchro sandbox 60 'step=1 ' | tail -n 1
headerwatch sandbox sb sandbox.mission.local
echo "plugin's ConfigMap in sandbox: $(kubectl get cm -n sandbox -o name | tr '\n' ' ')"
kubectl get cm argo-gatewayapi-configmap -n sandbox -o jsonpath='{.data}' 2>/dev/null | cut -c1-300; echo
kubectl logs -n argo-rollouts deploy/argo-rollouts --since=120s | grep -iE 'error|warn|denied|forbidden|configmap|header' | grep -v RemoveManagedRoutes | cut -c1-300 | tail -n 12
RO=sb watchro sandbox 240 '^(Healthy|Degraded)' | tail -n 2
echo "sandbox route after the release: $(kubectl get httproute sb -n sandbox -o jsonpath='{range .spec.rules[*]}[{range .backendRefs[*]}{.name}={.weight} {end}{range .matches[*].headers[*]}{.name}:{.value}{end}] {end}')"
k6wait sbload

