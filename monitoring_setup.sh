#!/bin/bash
set -e

# ============================
# CONFIGURACIÓN BÁSICA
# ============================
INSTALL_DIR="$HOME/.local"
BIN_DIR="$INSTALL_DIR/bin"
ETC_DIR="$INSTALL_DIR/etc"
VAR_DIR="$INSTALL_DIR/var"
TMP_DIR="/tmp"

mkdir -p "$BIN_DIR" "$ETC_DIR" "$VAR_DIR"

# ============================
# 1. PROMETHEUS
# ============================
echo "[+] Instalando Prometheus..."

cd "$TMP_DIR"
wget -q https://github.com/prometheus/prometheus/releases/download/v2.47.0/prometheus-2.47.0.linux-amd64.tar.gz
tar xzf prometheus-2.47.0.linux-amd64.tar.gz
cd prometheus-2.47.0.linux-amd64

mkdir -p "$ETC_DIR/prometheus" "$VAR_DIR/prometheus"
cp prometheus promtool "$BIN_DIR/"
cp -r consoles console_libraries "$ETC_DIR/prometheus/"

# Configuración Prometheus
cat > "$ETC_DIR/prometheus/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

rule_files:
  - "alert_rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'ubuntu_docker1'
    static_configs:
      - targets: ['192.168.122.44:9100']
        labels:
          instance: 'ubuntudocker1'

  - job_name: 'ubuntu_docker2'
    static_configs:
      - targets: ['192.168.122.99:9100']
        labels:
          instance: 'ubuntudocker2'
EOF

cat > "$ETC_DIR/prometheus/alert_rules.yml" <<'EOF'
groups:
  - name: system_alerts
    interval: 30s
    rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage is above 80% (current value: {{ $value }}%)"

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "Memory usage is above 85% (current value: {{ $value }}%)"

      - alert: HighNetworkTraffic
        expr: rate(node_network_receive_bytes_total{device="eth0"}[5m]) > 10485760
        for: 5m
        labels:
          severity: info
        annotations:
          summary: "High network traffic on {{ $labels.instance }}"
          description: "Network receive rate is above 10MB/s"
EOF

# ============================
# 2. ALERTMANAGER
# ============================
echo "[+] Instalando Alertmanager..."

cd "$TMP_DIR"
wget -q https://github.com/prometheus/alertmanager/releases/download/v0.26.0/alertmanager-0.26.0.linux-amd64.tar.gz
tar xzf alertmanager-0.26.0.linux-amd64.tar.gz
cd alertmanager-0.26.0.linux-amd64

mkdir -p "$ETC_DIR/alertmanager" "$VAR_DIR/alertmanager"
cp alertmanager amtool "$BIN_DIR/"

cat > "$ETC_DIR/alertmanager/alertmanager.yml" <<'EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'instance']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'web.hook'

receivers:
  - name: 'web.hook'
    webhook_configs:
      - url: 'http://localhost:3000/api/alerting/webhook'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
EOF

# ============================
# 3. LOKI
# ============================
echo "[+] Instalando Loki..."

cd "$TMP_DIR"
wget -q https://github.com/grafana/loki/releases/download/v2.9.2/loki-linux-amd64.zip
unzip -q loki-linux-amd64.zip
mv loki-linux-amd64 "$BIN_DIR/loki"
mkdir -p "$ETC_DIR/loki" "$VAR_DIR/loki"

cat > "$ETC_DIR/loki/loki-config.yaml" <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://localhost:9093

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20
EOF

# ============================
# 4. GRAFANA
# ============================
echo "[+] Instalando Grafana..."

cd "$TMP_DIR"
wget -q https://dl.grafana.com/oss/release/grafana-11.2.0.linux-amd64.tar.gz
tar xzf grafana-11.2.0.linux-amd64.tar.gz
mv grafana-11.2.0.linux-amd64 "$INSTALL_DIR/grafana"

# Configuración de Grafana
mkdir -p "$ETC_DIR/grafana"
cat > "$ETC_DIR/grafana/grafana.ini" <<'EOF'
[server]
http_port = 3000
domain = localhost

[security]
admin_user = admin
admin_password = admin

[unified_alerting]
enabled = true
EOF

# ============================
# EXPORTAR PATH
# ============================
if ! grep -q "$BIN_DIR" <<< "$PATH"; then
  echo "export PATH=\$PATH:$BIN_DIR" >> "$HOME/.bashrc"
  export PATH="$PATH:$BIN_DIR"
fi

# ============================
# FIN
# ============================
echo ""
echo "✅ Instalación completada."
echo "Binarios en: $BIN_DIR"
echo "Configuraciones en: $ETC_DIR"
echo ""
echo "Para iniciar servicios manualmente:"
echo "  prometheus --config.file=$ETC_DIR/prometheus/prometheus.yml"
echo "  alertmanager --config.file=$ETC_DIR/alertmanager/alertmanager.yml"
echo "  loki --config.file=$ETC_DIR/loki/loki-config.yaml"
echo "  $INSTALL_DIR/grafana/bin/grafana-server --config=$ETC_DIR/grafana/grafana.ini"
