# SDS Kubernetes automation

This repository contains the automation and GitOps code required to initialise and   
to configure the Kubernetes cluster for the SDS platform.   

This automation is using bash for initial cluster components (prerequisites)   
and afterwards is using ArgoCD or FluxCD for remaining cluster configuration (apps).   

Usage:   
1. Fillout params.   
2. Run "./kubernetes-init.sh"   
3. Check services on the Kubernetes cluster.   

NOTICE: This example works only with on-prem Kubernetes clusters, Route53 and Github docker image repository   

Solid Distributed Systems