#!/bin/bash

# Source variables
source ./params

# Install Helm cli
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Kubeseal cli
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v$SEALED_SECRETS_VERSION/kubeseal-$SEALED_SECRETS_VERSION-linux-amd64.tar.gz
tar xfz "kubeseal-$SEALED_SECRETS_VERSION-linux-amd64.tar.gz"
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# Install ArgoCD cli
sudo curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo chmod +x /usr/local/bin/argocd
rm -rf *.tar.gz*
rm kubeseal

# Namespaces
kubectl apply -f 00-cluster-init/00-namespaces.yaml

# Metallb
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
# echo "Important: if IPAdressPool already exists you have to delete it from the CRDs area of metallb-system namespace!"
kubectl apply -f 00-cluster-init/01-metallb-config.yaml

# NFS Storage
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=$NFS_SERVER \
    --set nfs.path=/volume1/kubernetes \
    -n nfs-provisioner
# kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass nfs-client -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get storageclass

# Nginx Ingress Controller - F5 version
export HELM_EXPERIMENTAL_OCI=1
kubectl apply -f 00-cluster-init/02-nginx-ingress-config.yaml
helm install nginx-ingress oci://ghcr.io/nginxinc/charts/nginx-ingress --version $NGINX_INGRESS_VERSION -f 00-cluster-init/02-nginx-helm-vars.yaml -n nginx-ingress
kubectl describe ingressclasses

# Sealed Secrets and initial secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets -n kube-system --set-string fullnameOverride=sealed-secrets-controller sealed-secrets/sealed-secrets

kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --fetch-cert > bitnami-pub-key/$PLATFORM_NAME-bitnami-pub.pem

kubectl create secret generic cluster-issuer-secret --dry-run=client -n cert-manager \
    --from-literal=access_key_id=$PLATFORM_AWS_ACCESS_KEY_ID \
    --from-literal=secret-access-key=$PLATFORM_SECRET_AWS_ACCESS_KEY -o yaml | \
kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --cert bitnami-pub-key/$PLATFORM_NAME-bitnami-pub.pem \
    --scope strict \
    --format yaml > 00-cluster-init/03-sealed-cluster-issuer-r53-secret.yaml

kubectl create secret generic external-dns-secret --dry-run=client -n external-dns \
    --from-literal=access-key-id=$PLATFORM_AWS_ACCESS_KEY_ID \
    --from-literal=access-key-secret=$PLATFORM_SECRET_AWS_ACCESS_KEY -o yaml | \
kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --cert bitnami-pub-key/$PLATFORM_NAME-bitnami-pub.pem \
    --scope strict \
    --format yaml > 00-cluster-init/05-sealed-external-dns-sealed-secret.yaml

# Cert Manager
kubectl apply -f 00-cluster-init/03-sealed-cluster-issuer-r53-secret.yaml
helm repo add jetstack https://charts.jetstack.io
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.crds.yaml
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version $CERT_MANAGER_VERSION
kubectl apply -f 00-cluster-init/04-cluster-issuer.yaml

# External DNS
export HELM_EXPERIMENTAL_OCI=1
kubectl apply -f 00-cluster-init/05-sealed-external-dns-sealed-secret.yaml
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
helm upgrade --install external-dns oci://registry-1.docker.io/bitnamicharts/external-dns \
    -f 00-cluster-init/06-external-dns-vars.yaml \
    --version $EXTERNAL_DNS_VERSION \
    --namespace external-dns

# ArgoCD
kubectl create secret generic $PLATFORM_NAME-git-secret --dry-run=client -n argocd \
    --from-file=privateSshKey=$HOME/.ssh/id_rsa \
    --from-file=sshPrivateKey=$HOME/.ssh/id_rsa -o yaml | \
kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --cert bitnami-pub-key/$PLATFORM_NAME-bitnami-pub.pem \
    --scope cluster-wide \
    --format yaml > 01-argo-system-init/01-sealed-git-secret.yaml

kubectl create secret generic $PLATFORM_NAME-aws-secret --dry-run=client -n argocd \
    --from-literal=AwsKeyId=$PLATFORM_AWS_ACCESS_KEY_ID \
    --from-literal=AwsSecretKey=$PLATFORM_SECRET_AWS_ACCESS_KEY -o yaml | \
kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --cert bitnami-pub-key/$PLATFORM_NAME-bitnami-pub.pem \
    --scope strict \
    --format yaml > 01-argo-system-init/03-sealed-argo-aws-secret.yaml

kubectl create secret docker-registry ghcr-docker-credentials --dry-run=client -n argocd \
    --docker-username=cbanciu667 \
    --docker-password=$GITHUB_PAT -o yaml | \
kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --cert bitnami-pub-key/$PLATFORM_NAME-bitnami-pub.pem \
    --scope strict \
    --format yaml > 01-argo-system-init/04-sealed-argo-ghcr-docker-credentials.yaml

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
kubectl apply -f 01-argo-system-init/01-sealed-argo-git-credentials.yaml
kubectl apply -f 01-argo-system-init/02-sealed-argo-git-git-repos.yaml
kubectl apply -f 01-argo-system-init/03-sealed-argo-aws-secret.yaml
kubectl apply -f 01-argo-system-init/04-sealed-argo-ghcr-docker-credentials.yaml
ARGOCD_PASSWORD=$(echo $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo))
ARGOCD_IP=$(echo $(kubectl get svc argocd-server -n argocd --output jsonpath='{.status.loadBalancer.ingress[0].ip}'))
echo "ArgoCD admin password is: $ARGOCD_PASSWORD"
echo "ArgoCD IP address is: $ARGOCD_IP"
argocd login $ARGOCD_IP:443 --username admin --password $ARGOCD_PASSWORD
argocd cluster add kubernetes-admin-$PLATFORM_NAME.local@$PLATFORM_NAME.local # kubectl context
# Install Argocd Image Updater
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
echo "You can now login to ArgoCD at https://$ARGOCD_IP with username admin and password $ARGOCD_PASSWORD"
echo "Add manually the infrastructure and the apps by using the commands bellow and following the process on the RgoCD web interface:"
echo "kubectl apply 01-argo-system-init/05-argocd-init-infrastructure.yaml"
echo "and"
echo "kubectl apply 01-argo-system-init/06-argocd-init-apps.yaml"

# FluxCD
flux bootstrap git \
  --context=KUBECTL_CONTEXT_NAME \
  --components-extra=image-reflector-controller,image-automation-controller \
  --url=ssh://git@github.com/cbanciu667/sds-fluxcd.git \
  --branch=master \
  --path=clusters/K8S_CLUSTER_NAME \
  --private-key-file=$HOME/.ssh/id_rsa \
  --interval=1m \
  --version=v2.0.1 \
  --verbose