#!/usr/bin/env bash
# Run 4: the header route with useHeaderRoutes, outside and inside Argo CD.
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
kubectl logs -n argo-rollouts deploy/argo-rollouts --since=90s | grep -iE 'header|managed|setHeaderRoute' | cut -c1-250 | tail -n 6
RO=sb watchro sandbox 240 '^(Healthy|Degraded)' | tail -n 2
echo "sandbox route after the release: $(kubectl get httproute sb -n sandbox -o jsonpath='{range .spec.rules[*]}[{range .backendRefs[*]}{.name}={.weight} {end}{range .matches[*].headers[*]}{.name}:{.value}{end}] {end}')"
k6wait sbload

H "H2. Header route in staging, under Argo CD"
k6start stgload staging.mission.local 20 200s
setval staging image.tag v2.2.1
setval staging rollout.testerSeconds 40
REV=$(push "Staging: v2.2.1 with a longer tester step"); refresh mission-staging
watchro staging 90 'step=1 ' | tail -n 1
headerwatch staging mission staging.mission.local
watchro staging 120 'step=[4-9] ' | tail -n 1
echo "at step 4 (20%): $(weights staging)"; gw; echo "   header -> $(sample staging.mission.local 6 'X-Canary: yes')"; kill $PF
echo "Argo CD at step 4: $(short mission-staging)"
echo "Argo CD staging: $(short mission-staging); sync operations so far: $(kubectl get application mission-staging -n argocd -o jsonpath='{.status.history}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
kubectl get events -n staging --field-selector involvedObject.kind=HTTPRoute -o custom-columns=T:.lastTimestamp,R:.reason,M:.message --no-headers 2>/dev/null | tail -n 5
kubectl get httproute mission -n staging -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{"\n"}{end}'
kubectl logs -n argo-rollouts deploy/argo-rollouts --since=90s | grep -iE 'header|managed' | cut -c1-250 | tail -n 6
watchro staging 300 '^(Healthy|Degraded)' | tail -n 2
k6wait stgload

echo "staging route after the release: $(weights staging)"
