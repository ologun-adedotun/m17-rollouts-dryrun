#!/usr/bin/env bash
# The CLIs, the app images (good, failing, slow) and the k6 image.
set -euo pipefail
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.5/argocd-linux-amd64
sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
curl -sSL -o /tmp/kar https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/kubectl-argo-rollouts-linux-amd64
sudo install -m 0755 /tmp/kar /usr/local/bin/kubectl-argo-rollouts
argocd version --client --short
kubectl argo rollouts version --short 2>/dev/null || kubectl argo rollouts version | head -1

IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app
K6=ghcr.io/${GITHUB_REPOSITORY}/maright-k6:v1
echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin >/dev/null
for v in v2.2.0 v2.2.1 v2.2.4 v2.2.5; do docker build -q --build-arg APP_VERSION=$v -t "$IMG:$v" app >/dev/null; done
docker build -q --build-arg APP_VERSION=v2.2.2 --build-arg ERROR_RATE=0.3 -t "$IMG:v2.2.2" app >/dev/null
docker build -q --build-arg APP_VERSION=v2.2.3 --build-arg DELAY_MS=400 -t "$IMG:v2.2.3" app >/dev/null
docker build -q -t "$K6" load >/dev/null
for v in v2.2.0 v2.2.1 v2.2.2 v2.2.3 v2.2.4 v2.2.5; do docker push -q "$IMG:$v" >/dev/null; done
docker push -q "$K6" >/dev/null
docker logout ghcr.io >/dev/null
docker rmi "$IMG:v2.2.1" >/dev/null
docker pull -q "$IMG:v2.2.1" >/dev/null 2>&1 && echo "anonymous pull: allowed" || echo "anonymous pull: REFUSED"
echo "v2.2.2 image says: $(docker run --rm "$IMG:v2.2.2" env | grep -E '^(APP_VERSION|ERROR_RATE|DELAY_MS)=' | tr '\n' ' ')"
