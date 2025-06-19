# Arbor Kubernetes Deployment Guide

This guide covers deploying Arbor's distributed AI agent orchestration system on Kubernetes clusters.

## 🚀 Quick Start

### Prerequisites

- **Kubernetes cluster** (1.21+)
- **kubectl** configured for your cluster
- **Helm 3.0+** (optional, for chart-based deployment)
- **Container registry** access (Docker Hub, ECR, GCR, etc.)

### Basic Deployment

```bash
# Apply basic Arbor deployment
kubectl apply -f k8s/

# Check deployment status
kubectl get pods -l app=arbor

# Access Arbor service
kubectl port-forward service/arbor 4000:4000
```

## 📋 Kubernetes Manifests

### Namespace Configuration

```yaml
# k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: arbor
  labels:
    name: arbor
    app.kubernetes.io/name: arbor
    app.kubernetes.io/instance: production
```

### ConfigMap

```yaml
# k8s/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: arbor-config
  namespace: arbor
data:
  ERLANG_COOKIE: "secure-cluster-cookie-change-in-production"
  MIX_ENV: "prod"
  PROMETHEUS_ENDPOINT: "http://prometheus:9090"
  JAEGER_ENDPOINT: "http://jaeger:14250"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: arbor-scripts
  namespace: arbor
data:
  health-check.sh: |
    #!/bin/bash
    set -e
    ./bin/arbor rpc "Application.get_application(:arbor_core)" > /dev/null 2>&1
```

### Secret Management

```yaml
# k8s/secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: arbor-secrets
  namespace: arbor
type: Opaque
data:
  # Base64 encoded values - update these!
  SECRET_KEY_BASE: <base64-encoded-secret>
  CAPABILITY_ENCRYPTION_KEY: <base64-encoded-key>
  DATABASE_URL: <base64-encoded-db-url>
```

### Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: arbor
  namespace: arbor
  labels:
    app: arbor
    version: v1.0.0
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: arbor
  template:
    metadata:
      labels:
        app: arbor
        version: v1.0.0
    spec:
      serviceAccountName: arbor
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
      containers:
      - name: arbor
        image: ghcr.io/azmaveth/arbor:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 4000
          name: http
          protocol: TCP
        - containerPort: 9001
          name: beam
          protocol: TCP
        - containerPort: 9464
          name: metrics
          protocol: TCP
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        envFrom:
        - configMapRef:
            name: arbor-config
        - secretRef:
            name: arbor-secrets
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - ./bin/health_check.sh
          initialDelaySeconds: 30
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - ./bin/health_check.sh
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        volumeMounts:
        - name: config-volume
          mountPath: /app/config/runtime.exs
          subPath: runtime.exs
        - name: data-volume
          mountPath: /app/data
      volumes:
      - name: config-volume
        configMap:
          name: arbor-runtime-config
      - name: data-volume
        persistentVolumeClaim:
          claimName: arbor-data
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: arbor
              topologyKey: kubernetes.io/hostname
```

### Service

```yaml
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: arbor
  namespace: arbor
  labels:
    app: arbor
spec:
  type: ClusterIP
  ports:
  - port: 4000
    targetPort: 4000
    protocol: TCP
    name: http
  - port: 9464
    targetPort: 9464
    protocol: TCP
    name: metrics
  selector:
    app: arbor
---
apiVersion: v1
kind: Service
metadata:
  name: arbor-headless
  namespace: arbor
  labels:
    app: arbor
spec:
  clusterIP: None
  ports:
  - port: 9001
    targetPort: 9001
    protocol: TCP
    name: beam
  selector:
    app: arbor
```

### Ingress

```yaml
# k8s/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: arbor-ingress
  namespace: arbor
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts:
    - arbor.yourdomain.com
    secretName: arbor-tls
  rules:
  - host: arbor.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: arbor
            port:
              number: 4000
```

### PersistentVolumeClaim

```yaml
# k8s/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: arbor-data
  namespace: arbor
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: fast-ssd
```

### ServiceAccount & RBAC

```yaml
# k8s/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: arbor
  namespace: arbor
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: arbor-cluster-role
rules:
- apiGroups: [""]
  resources: ["nodes", "pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: arbor-cluster-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: arbor-cluster-role
subjects:
- kind: ServiceAccount
  name: arbor
  namespace: arbor
```

## 🔧 Configuration

### Environment Variables

Essential environment variables for Kubernetes deployment:

```yaml
env:
- name: NODE_NAME
  value: "arbor@$(POD_IP).arbor-headless.arbor.svc.cluster.local"
- name: ERLANG_COOKIE
  valueFrom:
    secretKeyRef:
      name: arbor-secrets
      key: erlang-cookie
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: arbor-secrets
      key: database-url
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: arbor-secrets
      key: secret-key-base
```

### Resource Requirements

**Minimum Requirements per Pod:**
- CPU: 250m
- Memory: 512Mi

**Recommended for Production:**
- CPU: 500m
- Memory: 1Gi

**Scaling Guidelines:**
- **Small Workload**: 2-3 replicas
- **Medium Workload**: 3-5 replicas
- **Large Workload**: 5-10 replicas

## 📊 Monitoring & Observability

### Prometheus Integration

```yaml
# k8s/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: arbor-metrics
  namespace: arbor
spec:
  selector:
    matchLabels:
      app: arbor
  endpoints:
  - port: metrics
    path: /metrics
    interval: 30s
```

### Grafana Dashboard ConfigMap

```yaml
# k8s/grafana-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: arbor-grafana-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  arbor-dashboard.json: |
    {
      "dashboard": {
        "title": "Arbor - AI Agent Orchestration",
        "tags": ["arbor", "elixir", "agents"],
        "panels": [
          {
            "title": "Active Agents",
            "type": "stat",
            "targets": [
              {
                "expr": "sum(arbor_agent_active_count)",
                "legendFormat": "Active Agents"
              }
            ]
          }
        ]
      }
    }
```

## 🔒 Security Considerations

### Pod Security Standards

```yaml
# k8s/pod-security-policy.yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: arbor-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'emptyDir'
    - 'projected'
    - 'secret'
    - 'downwardAPI'
    - 'persistentVolumeClaim'
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
```

### Network Policies

```yaml
# k8s/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: arbor-network-policy
  namespace: arbor
spec:
  podSelector:
    matchLabels:
      app: arbor
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 4000
    - protocol: TCP
      port: 9464
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
```

## 🚀 Deployment Strategies

### Rolling Updates

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

### Blue-Green Deployment

```bash
# Deploy new version
kubectl apply -f k8s/deployment-green.yaml

# Test green deployment
kubectl port-forward service/arbor-green 4000:4000

# Switch traffic
kubectl patch service arbor -p '{"spec":{"selector":{"version":"green"}}}'

# Clean up blue deployment
kubectl delete deployment arbor-blue
```

### Canary Deployment

```yaml
# Using Argo Rollouts or Istio for advanced canary deployments
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: arbor-rollout
spec:
  strategy:
    canary:
      steps:
      - setWeight: 10
      - pause: {duration: 10m}
      - setWeight: 50
      - pause: {duration: 10m}
      - setWeight: 100
```

## 🔍 Troubleshooting

### Common Issues

**Pod Startup Problems:**
```bash
# Check pod logs
kubectl logs -f deployment/arbor -n arbor

# Check pod events
kubectl describe pod <pod-name> -n arbor

# Check resource constraints
kubectl top pods -n arbor
```

**Networking Issues:**
```bash
# Test service connectivity
kubectl run debug --image=busybox -it --rm -- sh
nslookup arbor.arbor.svc.cluster.local

# Check ingress status
kubectl describe ingress arbor-ingress -n arbor
```

**Persistent Storage Issues:**
```bash
# Check PVC status
kubectl get pvc -n arbor

# Check storage class
kubectl get storageclass
```

### Health Checks

```bash
# Manual health check
kubectl exec -it deployment/arbor -n arbor -- ./bin/health_check.sh

# Check application status
kubectl exec -it deployment/arbor -n arbor -- ./bin/arbor rpc ":observer.start()"
```

## 📈 Scaling

### Horizontal Pod Autoscaler

```yaml
# k8s/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: arbor-hpa
  namespace: arbor
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: arbor
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### Vertical Pod Autoscaler

```yaml
# k8s/vpa.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: arbor-vpa
  namespace: arbor
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: arbor
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: arbor
      minAllowed:
        cpu: 100m
        memory: 256Mi
      maxAllowed:
        cpu: 1
        memory: 2Gi
```

## 🔄 CI/CD Integration

### GitOps with ArgoCD

```yaml
# argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: arbor
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/azmaveth/arbor
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: arbor
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### Helm Chart Structure

```text
helm/arbor/
├── Chart.yaml
├── values.yaml
├── values-production.yaml
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── secrets.yaml
│   └── hpa.yaml
└── charts/
```

## 📚 Best Practices

### Resource Management
- Always set resource requests and limits
- Use QoS classes appropriately (Guaranteed for production)
- Monitor resource usage and adjust accordingly

### Security
- Run containers as non-root users
- Use Pod Security Standards
- Implement Network Policies
- Regularly update base images

### High Availability
- Use anti-affinity rules for pod distribution
- Deploy across multiple availability zones
- Implement proper health checks
- Use rolling updates with zero downtime

### Monitoring
- Expose metrics for monitoring
- Set up alerting for critical issues
- Use distributed tracing for debugging
- Monitor both application and infrastructure metrics

---

This guide provides a solid foundation for deploying Arbor on Kubernetes. Adjust configurations based on your specific cluster setup and requirements.