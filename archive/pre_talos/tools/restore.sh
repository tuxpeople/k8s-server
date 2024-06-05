#!/bin/bash

_pwd="$(pwd)"
_basedir="$(dirname $(which ${0}))"

cd ${_basedir} && cd $(git rev-parse --show-toplevel)

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pv-backup
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pv-backup
spec:
  selector:
    matchLabels:
      app: pv-backup
  replicas: 1
  template:
    metadata:
      labels:
        app: pv-backup
    spec:
      containers:
        - image: ubuntu
          imagePullPolicy: Always
          command:
            - sleep
            - inf
          name: pv-backup
          resources:
            requests:
              cpu: 10m
              memory: 50Mi
            limits:
              cpu: 1500m
              memory: 1000Mi
          volumeMounts:
            - mountPath: /pv-backup
              name: pv-backup
            - mountPath: /nfs-backup
              name: nfs-backup
      volumes:
        - name: pv-backup
          persistentVolumeClaim:
            claimName: pv-backup
        - name: nfs-backup
          nfs:
            server: 10.20.30.40
            path: /volume2/data/backup/kubernetes/pv-backup
EOF

echo disable flux
flux suspend kustomization --all -n flux-system > /dev/null

echo scale replicas down
kubectl scale deployment -n kube-system descheduler --replicas=0
# kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system --no-headers | awk '{ print $1 }' | xargs -L1 flux suspend kustomization
kubectl get deployments -A --no-headers | grep -v 'kube-system\|storage\|flux-system\|networking\|pv-backup' | awk '{ print $1 " " $2 }' | xargs -L1 kubectl scale deployment --replicas=0 -n
kubectl get statefulsets -A --no-headers | grep -v 'kube-system\|storage\|flux-system\|networking' | awk '{ print $1 " " $2 }' | xargs -L1 kubectl scale statefulset --replicas=0 -n

sleep 10

# kubectl get deployments -n storage --no-headers | awk '{ print $1 }' | xargs -L1 kubectl scale deployment --replicas=01 -n storage
# kubectl get statefulsets -n storage  --no-headers | awk '{ print $1 }' | xargs -L1 kubectl scale statefulset --replicas=1 -n storage

kubectl wait --for=condition=ready pod -l app=pv-backup --timeout=5m || exit 1

backuppod=$(kubectl get pod -l app=pv-backup -o name | cut -d'/' -f2)
kubectl exec -it ${backuppod} -- bash -c "mkdir -p /pv-backup/_tgz"
kubectl exec -it ${backuppod} -- bash -c "rm -rf /pv-backup/*"

date > pv-migrate.log
echo "" >> pv-migrate.log

for namespace in $(kubectl get ns --no-headers | awk '{ print $1 }'); do
    for pvc in $(kubectl get pvc --no-headers -n ${namespace} | awk '{ print $1 }' | grep -v pv-backup); do
        if kubectl exec -it ${backuppod} -- bash -c "test -f /nfs-backup/${namespace}--${pvc}.tar.gz"; then
            echo "Restore ${pvc} ..." | tee -a pv-migrate.log
            kubectl exec -it ${backuppod} -- bash -c "mkdir -p /pv-backup/${namespace}"
            kubectl exec -it ${backuppod} -- bash -c "cd /pv-backup/${namespace}; tar -xzf /nfs-backup/${namespace}--${pvc}.tar.gz"
            # kubectl describe pvc -n ${namespace} ${pvc} | grep Used | awk '{ print $3 }' | xargs -L1 kubectl delete pod -n ${namespace}
            pv-migrate migrate pv-backup ${pvc} --strategies "svc,mnt2,lbsvc" --no-progress-bar -i --source-path ${namespace}/${pvc}/ --source-namespace default --dest-namespace ${namespace} -d | tee -a pv-migrate.log | grep '❌\|✅ '
            kubectl exec -it ${backuppod} -- bash -c "rm -rf /pv-backup/${namespace}/${pvc}"
            # kubectl describe pvc -n ${namespace} ${pvc} | grep Used | awk '{ print $3 }' | xargs -L1 kubectl delete pod -n ${namespace}
            echo "" | tee -a pv-migrate.log
        fi
    done
done
date >> pv-migrate.log

sleep 10

# for ns in $(kubectl get ns --no-headers | grep -v 'kube-system\|storage\|flux-system' | awk '{ print $1 }')
# do
#     kubectl get deployments -n ${ns} --no-headers | grep -v pv-backup | awk '{ print $1 }' | xargs -L1 kubectl scale deployment --replicas=1 -n ${ns}
#     sleep 5
#     kubectl get statefulsets -n ${ns} --no-headers | awk '{ print $1 }' | xargs -L1 kubectl scale statefulset --replicas=1 -n ${ns}
#     sleep 5
# done

kubectl get deployments.apps -A --no-headers | grep pv-migrate | awk '{ print $1 " " $2 }' | xargs -L1 kubectl delete deployments -n
kubectl delete deployment pv-backup
kubectl get pods -A --no-headers | grep pv- | awk '{ print $1 " " $2 }' | xargs -L1 kubectl delete pod -n
kubectl delete persistentvolumeclaim pv-backup

for d in $(kubectl get deployments.apps -o wide --no-headers -A | grep -v descheduler | grep '0/0' | awk '{ print $1 ";" $2 }')
do
    kubectl scale deployment --replicas=1 -n $(echo $d | sed 's/;/ /g')
    sleep 5
done

for d in $(kubectl get statefulsets -o wide --no-headers -A | grep '0/0' | awk '{ print $1 ";" $2 }')
do
    kubectl scale statefulsets --replicas=1 -n $(echo $d | sed 's/;/ /g')
    sleep 5
done


echo enable flux
flux resume kustomization --all -n flux-system > /dev/null

for k in $(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system --no-headers | awk '{ print $1 }')
do
    flux reconcile kustomization $k &
done

# wait

# kubectl get helmrelease -A --no-headers | grep -v descheduler | awk '{ print $1 " " $2  }' | xargs -L1 flux reconcile helmrelease -n

# wait

# kubectl scale deployment -n kube-system descheduler --replicas=1
kubectl scale deployment -n kube-system descheduler --replicas=1

# kubectl get helmrelease -A --no-headers | awk '{ print $1 " " $2  }' | xargs -L1 flux reconcile helmrelease -n
