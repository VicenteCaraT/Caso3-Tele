#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# bootstrap.sh - Despliegue completo e idempotente del Caso 3
#
# Uso:
#   ./bootstrap.sh                  # construye/verifica todo (idempotente)
#   ./bootstrap.sh --destroy        # elimina el namespace completo
#
# Requisitos:
#   - kubectl con acceso al cluster (kubeconfig del lab)
#   - Acceso de red al FE_URL (desde la VM del lab funciona)
#   - k8s/secret.yaml presente (o mysql-secret ya aplicado en el cluster)
#   - Dump del dataset en data/google-mobility.sql.gz o en $HOME
#
# Variables de entorno (opcionales):
#   NS=vicenct-dev            FE_URL=https://vicenct-metabase.my.kube.um.edu.ar
#   DATA_FILE=...             K8S_DIR=...
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${K8S_DIR:-${REPO_DIR}/k8s}"
DATA_FILE="${DATA_FILE:-${REPO_DIR}/data/google-mobility.sql.gz}"
NS="${NS:-vicenct-dev}"
FE_URL="${FE_URL:-https://vicenct-metabase.my.kube.um.edu.ar}"

[ -f "$DATA_FILE" ] || DATA_FILE="${HOME}/google-mobility.sql.gz"
[ -f "$DATA_FILE" ] || { echo "ERROR: dump no encontrado (DATA_FILE=... )"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: falta '$1'"; exit 1; }; }
need kubectl; need gunzip; need curl; need jq

secret_get() { # secret_get <key> -> valor decodificado
  kubectl get secret mysql-secret -n "$NS" -o jsonpath="{.data.$1}" | base64 -d
}

if [ "${1:-}" = "--destroy" ]; then
  echo "==> Destruyendo namespace ${NS} (pods, PVCs, ingress... todo)"
  kubectl delete namespace "$NS" --ignore-not-found
  echo "==> Destroy completo. Para reconstruir: ./bootstrap.sh"
  exit 0
fi

echo "==> [1/7] Aplicando Secret y manifiestos base"
if [ -f "${K8S_DIR}/secret.yaml" ]; then
  kubectl apply -f "${K8S_DIR}/secret.yaml"
else
  kubectl get secret mysql-secret -n "$NS" >/dev/null 2>&1 || {
    echo "ERROR: falta k8s/secret.yaml y no existe mysql-secret en el cluster"; exit 1; }
fi
kubectl apply -f "${K8S_DIR}/mysql-pvc.yaml" \
              -f "${K8S_DIR}/mysql-service.yaml" \
              -f "${K8S_DIR}/mysql-statefulset.yaml"

echo "==> [2/7] Esperando MySQL Ready"
kubectl rollout status statefulset/mysql -n "$NS" --timeout=300s

echo "==> [3/7] Creando metabase_db + app_user (idempotente)"
APP_PASS="$(secret_get MB_DB_PASS)"
kubectl exec -i mysql-0 -n "$NS" -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' <<SQL
CREATE DATABASE IF NOT EXISTS metabase_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED WITH mysql_native_password BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON metabase_db.* TO 'app_user'@'%';
FLUSH PRIVILEGES;
SQL
echo "   metabase_db OK"

echo "==> [4/7] Importando dataset (solo si gam.mobility esta vacia)"
COUNT="$(kubectl exec mysql-0 -n "$NS" -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "SELECT COUNT(*) FROM gam.mobility;"' 2>/dev/null || true)"
[ -n "$COUNT" ] || COUNT=0
if [ "$COUNT" = "0" ]; then
  gunzip -c "$DATA_FILE" | kubectl exec -i mysql-0 -n "$NS" -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot gam'
  COUNT="$(kubectl exec mysql-0 -n "$NS" -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "SELECT COUNT(*) FROM gam.mobility;"' 2>/dev/null || echo 0)"
  echo "   Dataset importado: ${COUNT} filas"
else
  echo "   gam.mobility ya tiene ${COUNT} filas, se omite importacion"
fi

echo "==> [5/7] Desplegando Metabase + Ingress"
kubectl apply -f "${K8S_DIR}/metabase-deployment.yaml" \
              -f "${K8S_DIR}/metabase-service.yaml" \
              -f "${K8S_DIR}/metabase-ingress.yaml"
kubectl rollout status deployment/metabase -n "$NS" --timeout=900s

echo "==> [6/7] Job de setup (admin de Metabase, idempotente)"
kubectl delete job metabase-setup-job -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f "${K8S_DIR}/metabase-setup-configmap.yaml" \
              -f "${K8S_DIR}/metabase-setup-job.yaml"
kubectl wait --for=condition=complete job/metabase-setup-job -n "$NS" --timeout=300s

echo "==> [7/7] Contenido: cards, dashboards y archivado (idempotente)"
DB_PASS="$(secret_get MYSQL_PASSWORD)"
ADMIN_EMAIL="$(secret_get MB_ADMIN_EMAIL)"
ADMIN_PASS="$(secret_get MB_ADMIN_PASSWORD)"
SETUP_OUT="$("${SCRIPT_DIR}/metabase-setup.sh" "${FE_URL}" mysql-service "${DB_PASS}" "${ADMIN_EMAIL}" "${ADMIN_PASS}")"
echo "$SETUP_OUT"

DASH_ID="$(echo "$SETUP_OUT" | grep -oP 'dashboard=\K[0-9]+' | head -1)"
DASH_FILTER_ID="$(echo "$SETUP_OUT" | grep -oP 'dashboard_filtros=\K[0-9]+' | head -1)"

echo
echo "==================================================================="
echo "  DESPLIEGUE COMPLETO"
echo "==================================================================="
echo "  URL Metabase:          ${FE_URL}"
echo "  Health check:          $(curl -sk -o /dev/null -w 'HTTP %{http_code}' --max-time 15 "${FE_URL}/api/health" || echo 'fallo (revisar red)')"
echo "  Dashboard:             ${FE_URL}/dashboard/${DASH_ID}"
echo "  Dashboard con filtros: ${FE_URL}/dashboard/${DASH_FILTER_ID}"
echo "  Usuario admin:         ${ADMIN_EMAIL}"
echo "  Contraseña admin:      ${ADMIN_PASS}"
echo "  Dataset:               gam.mobility = ${COUNT} filas"
echo "  App DB de Metabase:    metabase_db (en MySQL, persistente)"
echo "  Namespace:             ${NS}"
echo "-------------------------------------------------------------------"
echo "  Estado del stack:"
kubectl get pods,svc,ingress,pvc -n "$NS" 2>/dev/null | grep -v node-debugger
echo "==================================================================="