#!/bin/bash

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
      storage: 100Gi
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
              cpu: 1000m
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

sleep 5

kubectl wait --for=condition=ready pod -l app=pv-backup --timeout=5m || exit 1

backuppod=$(kubectl get pod -l app=pv-backup -o name | cut -d'/' -f2)
kubectl exec -it ${backuppod} -- bash -c "mkdir -p /pv-backup/_tgz"
kubectl exec -it ${backuppod} -- bash -c "rm -rf /pv-backup/*"

# echo disable flux
# flux suspend kustomization --all -n flux-system > /dev/null

for namespace in $(kubectl get ns --no-headers | awk '{ print $1 }'); do
    for pvc in $(kubectl get pvc --no-headers -n ${namespace} | awk '{ print $1 }' | grep -v pv-backup); do
        echo "Backup ${pvc} ..."
        kubectl exec -it ${backuppod} -- bash -c "mkdir -p /pv-backup/${namespace}"
        # usedby=$(kubectl describe -n ${namespace} pvc ${pvc} | grep "Used By" | awk '{print $3}')
        # controlledby=$(kubectl describe -n ${namespace} pod ${usedby} | grep "Controlled By" | awk '{print $3}')
        # if echo ${controlledby} | grep "StatefulSet\|Deployment"
        # then
        #     kubectl scale -n ${namespace} --replicas 0 ${controlledby}
        # else
        #     controlledby1=$(kubectl describe -n ${namespace} ${controlledby} | grep "Controlled By" | awk '{print $3}')
        #     if echo ${controlledby1} | grep "StatefulSet\|Deployment"
        #     then
        #         kubectl scale -n ${namespace} --replicas 0 ${controlledby1}
        #     else
        #         controlledby2=$(kubectl describe -n ${namespace} ${controlledby} | grep "Controlled By" | awk '{print $3}')
        #         if echo ${controlledby2} | grep "StatefulSet\|Deployment"
        #         then
        #             kubectl scale -n ${namespace} --replicas 0 ${controlledby2}
        #         fi
        #     fi
        # fi
        # echo Waiting for pvc not being used
        # max_retry=10
        # counter=0
        # until kubectl describe -n ${namespace} pvc ${pvc} | grep "Used By" | awk '{print $3}' | grep "<none>"
        # do
        #     sleep 5
        #     [[ counter -eq $max_retry ]] && echo "Failed!" && break
        #     kubectl describe -n ${namespace} pvc ${pvc} | grep "Used By" | awk '{print $3}' | grep "<none>"
        #     echo -n .
        #     ((counter++))
        # done
        pv-migrate migrate ${pvc} pv-backup -i --dest-path ${namespace}/${pvc} --dest-namespace default --source-namespace ${namespace} -d | grep '❌\|✅ '
        kubectl exec -it ${backuppod} -- bash -c "rm -f /nfs-backup/${namespace}--${pvc}.tar.gz; cd /pv-backup/${namespace}; tar -czf /nfs-backup/${namespace}--${pvc}.tar.gz ${pvc}; rm -rf ${pvc}"
        echo ""
    done
done

sleep 10

# echo enable flux
# flux resume kustomization --all -n flux-system > /dev/null

kubectl get pods -A --no-headers | grep pv- | awk '{ print $1 " " $2 }' | xargs -L1 kubectl delete pod -n
kubectl delete deployment pv-backup
kubectl delete persistentvolumeclaim pv-backup
