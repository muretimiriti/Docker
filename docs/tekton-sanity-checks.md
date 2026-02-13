# Tekton Sanity Checks

## Check RBAC Bindings

### Verify the clusterrolebinding exists and is correct

```bash
kubectl get clusterrolebinding -tekton-triggers-clusterrolebinding -o yaml
```

### Check what permissions the service account has

```bash
kubectl auth can-i list triggers --as=system:serviceaccount:default:tekton-triggers-sa
kubectl auth can-i list eventlisteners --as=system:serviceaccount:default:tekton-triggers-sa
kubectl auth can-i list triggerbindings --as=system:serviceaccount:default:tekton-triggers-sa
```

### Verify the role binding

```bash
kubectl get rolebinding -n default tekton-triggers-binding -o yaml
```

## Check if EventListener is Running and Listening

### Check pod status

```bash
kubectl get pods -l eventlistener=event-listener
```

### Check if it's actually listening on port 8080

```bash
kubectl get svc el-event-listener
kubectl describe svc el-event-listener
```

### Check endpoint (is pod connected to service?)

```bash
kubectl get endpoints el-event-listener
```

### Test connection from inside the cluster

```bash
kubectl run test-pod --image=curlimages/curl -it --rm -- curl http://el-event-listener:8080/live
```

### Check logs for successful startup

```bash
kubectl logs -l eventlistener=event-listener | grep -i "listening\|started\|ready"
```

## Check if Triggers can Reach EventListener

### List all triggers in the namespace

```bash
kubectl get triggers
```

### Check a specific trigger

```bash
kubectl describe trigger <trigger-name>
```

### Check if trigger can see the eventlistener

```bash
kubectl get eventlisteners
```
