# Caso 3 – Teleinformática: Metabase + MySQL 8 sobre Kubernetes

Despliegue de **Metabase** y **MySQL 8** sobre Kubernetes (Rancher / RKE2) con almacenamiento persistente **Longhorn** e **Ingress NGINX**, reutilizando el dataset `google-mobility.sql.gz`.

## Arquitectura

```
Usuario (navegador)
   |
   v
Ingress NGINX  ->  vicenct-metabase.my.kube.um.edu.ar
   |
   v
Service Metabase (ClusterIP :3000)
   |
   v
Deployment Metabase (metabase/metabase:v0.62.13)
   |  \ app DB: metabase_db (MySQL)
   v
Service MySQL (ClusterIP :3306)  <-  mysql-service
   |
   v
StatefulSet MySQL 8 (mysql:8.0)
   |  \ dataset: gam.mobility
   v
PVC 5Gi
   |
   v
Longhorn (almacenamiento persistente)
```

## Recursos

| Recurso | Archivo |
|---|---|
| Secret MySQL | `k8s/secret.yaml` (generado localmente, NO versionado) |
| Secret ejemplo (para Git) | `k8s/secret.example.yaml` |
| PVC MySQL | `k8s/mysql-pvc.yaml` |
| Service MySQL | `k8s/mysql-service.yaml` |
| StatefulSet MySQL 8 | `k8s/mysql-statefulset.yaml` |
| Deployment Metabase | `k8s/metabase-deployment.yaml` |
| Service Metabase | `k8s/metabase-service.yaml` |
| Setup automático Metabase (script) | `k8s/metabase-setup-configmap.yaml` |
| Setup automático Metabase (Job) | `k8s/metabase-setup-job.yaml` |
| Setup contenido Metabase (cards/dashboards) | `scripts/metabase-setup.sh` |
| Ingress | `k8s/metabase-ingress.yaml` |

Namespace de trabajo: `vicenct-dev`

## Acceso

- **URL:** `https://vicenct-metabase.my.kube.um.edu.ar`
- **Usuario admin:** `admin@proyecto.com`
- **Contraseña admin:** generada automáticamente (ver Secret `mysql-secret`, clave `MB_ADMIN_PASSWORD`)

## Pasos del despliegue

### 1. Prerequisitos del cluster

- Cluster RKE2 v1.35 vía Rancher (`cluster-01`)
- StorageClass **`longhorn`** instalada (default)
- IngressClass **`nginx`** instalado
- Kubeconfig en la VM (`~/.kube/config`), namespace `vicenct-dev`

### 2. Dataset

- `data/google-mobility.sql.gz` (dump de Google Mobility Report)
- El dump NO trae `CREATE DATABASE` ni `USE` → se importa directo a la base `gam` como tabla `mobility`:

```bash
gunzip -c ~/google-mobility.sql.gz | kubectl exec -i mysql-0 -n vicenct-dev -- \
  sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql -uroot gam"
```

- Resultado: **411.307 filas**, rango 2020-02-15 → 2022-10-15. Mendoza Province + Capital Department presentes.

### 3. MySQL 8 (StatefulSet + PVC)

- Imagen `mysql:8.0` con `--default-authentication-plugin=mysql_native_password` (compatibilidad con Metabase)
- PVC 5Gi sobre `longhorn`
- Init container `remove-lost-found` (bug de `lost+found` en volúmenes)
- Probes: `mysqladmin ping -h 127.0.0.1` (sin credenciales)
- `nodeSelector` al nodo `cluster-01-workers-4phg9-6w74j` (el nodo `cluster-01-workers2-kcnjb-c4wsf` tiene un bug de formateo en Longhorn: `mke2fs ... apparently in use by the system`)
- Bases: `gam` (dataset) + `metabase_db` (app DB de Metabase), usuarios `metabase` y `app_user`

### 4. Metabase

- Imagen `metabase/metabase:v0.62.13` (última estable)
- **Base interna en MySQL** (schema `metabase_db`, env `MB_DB_*`) → la configuración persiste en Longhorn, el setup se hace UNA sola vez
- `MB_ADD_SAMPLE_DATASET=false`
- Probes `httpGet /api/health` con tolerancia amplia (Metabase tarda varios minutos en el primer arranque: inicialización H2→MySQL y migraciones Liquibase)
- **Setup 100% automático** vía Job one-shot (`metabase-setup-job`):
  1. Espera `/api/health` = ok
  2. Toma el `setup-token` de `/api/session/properties`
  3. `POST /api/setup` con admin + conexión MySQL a `gam`
  4. Idempotente: si el token es nulo (ya configurado), sale sin hacer nada
- La conexión a `gam` se registra además vía `POST /api/database` (en v0.62 el campo `database` del setup no se aplica)

### 5. Dashboard (creado vía API)

`scripts/metabase-setup.sh` archiva todo el contenido de muestra y deja:

| Pregunta | Tipo | Consulta |
|---|---|---|
| Google Mobility | Tabla | Dataset `mobility` filtrado a `country_region = Argentina` |
| Google Mobility - Evolución | Líneas | avg de retail/grocery/parks/workplaces por fecha (Argentina) |

| Dashboard | Contenido |
|---|---|
| Google Mobility - Dashboard | Card tabla (12x8) |
| Google Mobility - Dashboard Filtros | Card tabla (24x10) + gráfico (24x8), con filtros **Región 1** (sub_region_1), **Región 2** (sub_region_2) y **Fecha** (date/range) conectados a ambas cards |

Uso: `./scripts/metabase-setup.sh https://<host> mysql-service <db_pass> <admin_email> <admin_pass>`
(la conexión MySQL `Google Mobility` se crea/reusa, idempotente)

### 6. Ingress

```yaml
spec:
  ingressClassName: nginx   # obligatorio en RKE2 v1.35 (la anotación kubernetes.io/ingress.class está deprecada)
  rules:
    - host: vicenct-metabase.my.kube.um.edu.ar
      ...
```

El DNS `vicenct-metabase.my.kube.um.edu.ar` ya resuelve al firewall del lab (`200.51.41.176`).

## Persistencia (verificada)

Borrado del pod `mysql-0` → recreado por el StatefulSet (UID distinto) → **411.307 filas intactas** y `metabase_db` completa. Los datos viven en Longhorn.

## Capturas sugeridas para el informe

1. `kubectl get all,pvc -n vicenct-dev` (estado completo)
2. `kubectl exec mysql-0 -- mysql -e "SELECT COUNT(*) FROM gam.mobility"` (dataset)
3. Resultados del dashboard en el navegador
4. `kubectl logs job/metabase-setup-job` (setup automático)
5. UIDs del pod antes/después del borrado (persistencia)
6. `curl https://vicenct-metabase.my.kube.um.edu.ar/api/health` (acceso público)

## Notas y decisiones

- El Secret `k8s/secret.yaml` con contraseñas reales está en `.gitignore` (no se versiona)
- El setup de contenido (cards, dashboards, archivado de lo demás) se hace con `scripts/metabase-setup.sh`
- Los restarts iniciales de Metabase fueron por probes demasiado estrictas durante el primer arranque y una migración interrumpida; se resolvió con tolerancia de probes amplia + recreación del schema `metabase_db`
