# Monitoring Stack — Quick Reference

## Install Commands

```bash
# Create namespace
kubectl create namespace monitoring

# Add Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Prometheus + Grafana
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/prometheus-values.yaml

# Install Loki (log aggregation)
helm install loki grafana/loki \
  -n monitoring -f monitoring/loki-values.yaml

# Install Promtail (log shipping agent)
helm install promtail grafana/promtail \
  -n monitoring -f monitoring/promtail-values.yaml

# Apply ServiceMonitors for our app
kubectl apply -f monitoring/service-monitors.yaml
```

## Access

```bash
# Grafana (dashboards) — admin/admin123
kubectl port-forward -n monitoring service/prometheus-grafana 3000:80

# Prometheus (raw metrics/queries)
kubectl port-forward -n monitoring service/prometheus-kube-prometheus-prometheus 9090:9090

# Loki (log queries)
kubectl port-forward -n monitoring service/loki 3100:3100
```

## Uninstall

```bash
helm uninstall promtail -n monitoring
helm uninstall loki -n monitoring
helm uninstall prometheus -n monitoring
kubectl delete namespace monitoring
```
