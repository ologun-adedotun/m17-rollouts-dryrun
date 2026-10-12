#!/usr/bin/env bash
# Module 17 authoring test, run 2: the fixed takeover mode and the route ignore without RespectIgnoreDifferences.
set -uo pipefail
source ci/lib.sh

H "S1. Platform from Git"
t0=$(now); installargo; echo "Argo CD installed in $(( $(now) - t0 ))s"
kubectl create namespace load >/dev/null
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall $APPS 900
kubectl get applications -n argocd
echo "Rollouts controller image: $(kubectl get deploy -n argo-rollouts -o jsonpath='{.items[*].spec.template.spec.containers[0].image}')"
echo "Rollouts deployments: $(kubectl get deploy -n argo-rollouts -o name | tr '\n' ' ')"
echo "plugin lines in the controller log:"; kubectl logs -n argo-rollouts deploy/argo-rollouts --tail=400 | grep -i plugin | cut -c1-220 | head -n 6
echo "plugin config: $(kubectl get cm argo-rollouts-config -n argo-rollouts -o jsonpath='{.data.trafficRouterPlugins}' | tr '\n' ' ' | cut -c1-300)"
echo "controller ClusterRole API groups: $(kubectl get clusterrole argo-rollouts -o jsonpath='{range .rules[*]}{.apiGroups[*]} {end}' | tr ' ' '\n' | sort -u | tr '\n' ' ')"

H "S2. Where to measure a canary: Envoy's cluster names"
EP=$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=mission -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system "pod/$EP" 19001:19001 >/dev/null 2>&1 & PFE=$!; sleep 4
curl -s -m 5 http://127.0.0.1:19001/stats/prometheus | grep -o 'envoy_cluster_name="[^"]*"' | sort -u | head -n 12
kill $PFE

H "M. Deployment to Rollout under load: staging via workloadRef, production replaced directly"
k6start mig-stg staging.mission.local 20 150s
k6start mig-prd mission.local 20 150s
sleep 15
setval staging workload migrate
setval production workload rollout
REV=$(push "Staging: migrate to a Rollout; production: replace with a Rollout")
refresh mission-staging mission-production
waitapp mission-staging Synced Healthy "$REV" 300
waitapp mission-production Synced Healthy "$REV" 300
for i in 1 2 3 4 5 6; do echo "$(ts) staging deploy replicas=$(kubectl get deploy mission -n staging -o jsonpath='{.spec.replicas}/{.status.readyReplicas}' 2>&1 | cut -c1-40) rollout=$(ro staging)"; sleep 10; done
k6wait mig-stg; k6wait mig-prd
echo "production now: $(kubectl get deploy,rollout -n production --no-headers 2>&1 | awk '{print $1}' | tr '\n' ' ')"
k6start mig2 staging.mission.local 20 120s
sleep 10
setval staging workload rollout
REV=$(push "Staging: the Rollout owns its template; the Deployment goes")
refresh mission-staging
waitapp mission-staging Synced Healthy "$REV" 300
k6wait mig2
echo "staging now: $(kubectl get deploy,rollout -n staging --no-headers 2>&1 | awk '{print $1}' | tr '\n' ' ')"
echo "HPA target: $(kubectl get hpa mission -n staging -o jsonpath='{.spec.scaleTargetRef.kind}/{.spec.scaleTargetRef.name}') $(kubectl get hpa mission -n staging --no-headers | awk '{print $3, $4, $5, $6, $7}')"
echo "route: $(weights staging)"

H "C1. A good canary in staging (v2.2.1), under load"
k6start c1 staging.mission.local 20 240s
sleep 5
setval staging image.tag v2.2.1
REV=$(push "Staging: v2.2.1"); T0=$(now); refresh mission-staging
watchro staging 60 'step=1 '
gw
echo "at step 1, header X-Canary: yes -> $(sample staging.mission.local 10 'X-Canary: yes')"
echo "at step 1, no header          -> $(sample staging.mission.local 10)"
kill $PF
watchro staging 120 'step=[3-9] '
gw; echo "at 20%: $(sample staging.mission.local 50)"; kill $PF
watchro staging 120 'step=[5-9] '
gw; echo "at 50%: $(sample staging.mission.local 50)"; kill $PF
watchro staging 200 '^Healthy'
echo "canary finished $(( $(now) - T0 ))s after the commit; Argo CD: $(short mission-staging); route: $(weights staging)"
runresults staging 3
k6wait c1

badcanary() { # NAME TAG
  H "$1"
  local j=${2//./-}
  k6start "bad-$j" staging.mission.local 20 200s
  sleep 5
  setval staging image.tag "$2"
  REV=$(push "Staging: $2"); T0=$(now); refresh mission-staging
  watchro staging 240 '^Degraded'
  echo "aborted $(( $(now) - T0 ))s after the commit"
  echo "rollout: $(ro staging)"
  echo "route after abort: $(weights staging)"
  echo "Argo CD: $(short mission-staging) $(kubectl get application mission-staging -n argocd -o jsonpath='{.status.health.message}' | cut -c1-150)"
  runresults staging 3
  k6wait "bad-$j" 300s
  k6start "rev-$j" staging.mission.local 20 60s
  T0=$(now); REV=$(revertpush); refresh mission-staging
  watchro staging 180 '^Healthy'
  echo "revert to Healthy: $(( $(now) - T0 ))s; Argo CD: $(short mission-staging)"
  k6wait "rev-$j"
}
badcanary "C2. A canary that fails 30% of requests (v2.2.2)" v2.2.2
badcanary "C3. A canary that is slow, not failing (v2.2.3)" v2.2.3

H "P. Production: promotion with a manual pause"
setval production image.tag v2.2.1
REV=$(push "Production: v2.2.1"); T0=$(now); refresh mission-production
watchro production 300 '^Paused.*step=7 '
echo "paused $(( $(now) - T0 ))s after the commit; Argo CD health: $(kubectl get application mission-production -n argocd -o jsonpath='{.status.health.status}')"
kubectl port-forward svc/argocd-server -n argocd 8444:443 >/dev/null 2>&1 & PFA=$!; sleep 5
INIT=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d); echo "::add-mask::$INIT"
PPW=$(openssl rand -base64 24); echo "::add-mask::$PPW"
TPW=$(openssl rand -base64 24); echo "::add-mask::$TPW"
argocd login localhost:8444 --username admin --password "$INIT" --insecure >/dev/null 2>&1
argocd account update-password --account promoter --current-password "$INIT" --new-password "$PPW" >/dev/null 2>&1 && echo "promoter password set"
argocd account update-password --account trainer --current-password "$INIT" --new-password "$TPW" >/dev/null 2>&1 && echo "trainer password set"
argocd login localhost:8444 --username trainer --password "$TPW" --insecure >/dev/null 2>&1
echo "trainer resume: $(argocd app actions run mission-production resume --kind Rollout --resource-name mission 2>&1 | tail -n 1 | cut -c1-200)"
argocd login localhost:8444 --username promoter --password "$PPW" --insecure >/dev/null 2>&1
echo "promoter sees actions: $(argocd app actions list mission-production --kind Rollout 2>&1 | tr -s ' ' | tr '\n' ';' | cut -c1-250)"
echo "promoter sync: $(argocd app sync mission-production 2>&1 | tail -n 1 | cut -c1-200)"
echo "promoter set: $(argocd app set mission-production --sync-policy none 2>&1 | tail -n 1 | cut -c1-200)"
T1=$(now)
echo "promoter resume: $(argocd app actions run mission-production resume --kind Rollout --resource-name mission 2>&1 | tail -n 1 | cut -c1-200) (exit $?)"
argocd logout localhost:8444 >/dev/null 2>&1; kill $PFA; unset INIT PPW TPW
watchro production 120 '^Healthy'
echo "Healthy $(( $(now) - T1 ))s after the resume; Argo CD: $(short mission-production)"

H "B. Blue-green in a sandbox namespace"
kubectl create namespace bluegreen >/dev/null
bg() { helm template bg charts/maright-app -n bluegreen -f deploy/envs/staging/values.yaml \
  --set workload=rollout --set rollout.strategy=blueGreen --set route.enabled=false --set autoscaling.enabled=false \
  --set networkPolicy.enabled=false --set image.tag="$1" | kubectl apply -n bluegreen -f - >/dev/null; }
export RO=bg
bg v2.2.1
sleep 5; watchro bluegreen 180 '^Healthy'
bgver() { kubectl run "c$RANDOM" -n bluegreen --rm -i --restart=Never --image=curlimages/curl:8.17.0 --quiet -- -s -m 3 "http://$1.bluegreen.svc.cluster.local/" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("version"))
except Exception: print("error")'; }
bg v2.2.5
T0=$(now)
watchro bluegreen 180 '^Paused'
echo "paused $(( $(now) - T0 ))s after the change"
runresults bluegreen 1
echo "active: $(bgver bg)  preview: $(bgver bg-preview)"
kubectl create job bgload -n load --image="$K6" -- k6 run -q -e TARGET=http://bg.bluegreen.svc.cluster.local/ -e HOST=x -e RATE=30 -e DURATION=60s /scripts/load.js >/dev/null
sleep 15
T0=$(now); kubectl argo rollouts promote bg -n bluegreen >/dev/null
for i in $(seq 10); do v=$(bgver bg); echo "+$(( $(now) - T0 ))s active=$v"; [ "$v" = v2.2.5 ] && break; sleep 1; done
sleep 10
echo "replica sets: $(kubectl get rs -n bluegreen --no-headers | awk '{print $1"="$3"/"$4}' | tr '\n' ' ')"
T0=$(now); kubectl argo rollouts undo bg -n bluegreen >/dev/null
watchro bluegreen 120 '^(Paused|Healthy)'
echo "after undo: $(ro bluegreen | cut -c1-80) at +$(( $(now) - T0 ))s; active: $(bgver bg)"
kubectl argo rollouts promote bg -n bluegreen >/dev/null
for i in $(seq 15); do v=$(bgver bg); echo "+$(( $(now) - T0 ))s active=$v"; [ "$v" = v2.2.1 ] && break; sleep 1; done
k6wait bgload 200s

unset RO
echo done
