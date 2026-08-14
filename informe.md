# Informe – Caso 3 de Teleinformática
## Despliegue de Metabase + MySQL 8 sobre Kubernetes

**Autor:** Vicente Cara Torresan
**Fecha:** 14/08/2026
**Repositorio:** https://github.com/VicenteCaraT/Caso3-Tele

---

## 1. Resumen

Se desplegó sobre el cluster Kubernetes del laboratorio (RKE2 v1.35.4 gestionado por Rancher) una plataforma de visualización de datos compuesta por:

- **MySQL 8.0.46** como base de datos relacional con almacenamiento persistente **Longhorn**, conteniendo el dataset público *Google COVID-19 Community Mobility Reports* (411.307 registros).
- **Metabase v0.62.13** como herramienta de BI, con su base interna propia sobre MySQL (schema `metabase_db`), configurada y poblada de dashboards **de forma 100 % automática** (Job de Kubernetes + API de Metabase).
- Exposición pública mediante **Ingress NGINX** en `https://vicenct-metabase.my.kube.um.edu.ar`.

El despliegue completo se reproduce con **un solo comando** (`scripts/bootstrap.sh`, idempotente), validado mediante una prueba real de destrucción y reconstrucción total.

---

## 2. Arquitectura

```
Navegador (internet)
     │
     ▼  https://vicenct-metabase.my.kube.um.edu.ar
Ingress NGINX  (ingressClassName: nginx)
     │
     ▼
Service metabase-service  (ClusterIP :3000)
     │
     ▼
Deployment Metabase  (metabase/metabase:v0.62.13)
     │  └─ app DB interna: metabase_db (tablas propias de Metabase)
     │
     ▼
Service mysql-service  (ClusterIP :3306)
     │
     ▼
StatefulSet MySQL 8  (mysql:8.0)  ── dataset: gam.mobility
     │
     ▼
PVC mysql-pvc (5Gi, RWO)
     │
     ▼
StorageClass longhorn  (almacenamiento distribuido)
```

> **CAPTURA PARA EL INFORME:** diagrama de arquitectura (este diagrama o uno equivalente dibujado) como primera figura del informe.

| Componente | Recurso | Imagen / Clase |
|---|---|---|
| Base de datos | StatefulSet `mysql` + PVC 5Gi | `mysql:8.0` |
| BI | Deployment `metabase` | `metabase/metabase:v0.62.13` |
| Persistencia | PVC `mysql-pvc` | StorageClass `longhorn` |
| Exposición | Ingress `metabase-ingress` | IngressClass `nginx` |
| Setup automático | Job `metabase-setup-job` | `alpine` + script |

---

## 3. Infraestructura del laboratorio

- **Cluster:** `cluster-01` (Rancher: `rancher.kube.um.edu.ar/k8s/clusters/c-m-ckf5sprd`)
- **Versión:** RKE2 **v1.35.4** (3 masters + 14 workers = 17 nodos Ready, Ubuntu 24.04)
- **Namespace:** `vicenct-dev` (proyecto Rancher `p-gvv8n`)
- **StorageClass:** `longhorn` (default) y `longhorn-static`
- **IngressClass:** `nginx` (instalado con RKE2)

**Nota de cluster:** el nodo `cluster-01-workers2-kcnjb-c4wsf` presenta un bug de formateo en Longhorn (`mke2fs ... apparently in use by the system`), por lo que **MySQL se fijó mediante `nodeSelector`** al nodo `cluster-01-workers-4phg9-6w74j`. Metabase se ubicó en el mismo nodo para minimizar latencia en las migraciones (el bus de red entre nodos penaliza cada changeset de Liquibase).

> **CAPTURA PARA EL INFORME:** `kubectl get nodes` (17 nodos Ready con versión RKE2).
> **CAPTURA PARA EL INFORME:** namespace `vicenct-dev` con su label de proyecto Rancher (`field.cattle.io/projectId: p-gvv8n`).
> **CAPTURA PARA EL INFORME:** `kubectl get storageclass` (longhorn como default) e `kubectl get ingressclass` (nginx).

---

## 4. Despliegue paso a paso

### 4.1 Secret de credenciales

`k8s/secret.yaml` (Opaque) con las credenciales de MySQL, del schema interno de Metabase y del usuario admin de Metabase. **No se versiona** (`.gitignore`); se versiona `k8s/secret.example.yaml` con valores ficticios.

```
MYSQL_ROOT_PASSWORD, MYSQL_DATABASE=gam, MYSQL_USER=metabase, MYSQL_PASSWORD
MB_DB_TYPE/HOST/PORT/DBNAME/USER/PASS   (app DB interna de Metabase → metabase_db)
MB_ADMIN_EMAIL, MB_ADMIN_PASSWORD, MB_SITE_NAME
```

> **CAPTURA PARA EL INFORME:** `kubectl get secret mysql-secret -o yaml` (enmascarando valores) y `k8s/secret.example.yaml` del repo.
> **CAPTURA PARA EL INFORME:** `.gitignore` mostrando que `k8s/secret.yaml` no se versiona.

### 4.2 MySQL 8 (StatefulSet)

- `mysql:8.0` con `--default-authentication-plugin=mysql_native_password` (compatibilidad de drivers con Metabase).
- **PVC 5Gi** sobre `longhorn`, montado en `/var/lib/mysql`.
- **Init container `remove-lost-found`**: corrige el error clásico de formateo de volúmenes (`lost+found` bloquea el datadir).
- Probes con `mysqladmin ping -h 127.0.0.1` (sin credenciales): readiness `initialDelaySeconds: 30, failureThreshold: 6`; liveness `initialDelaySeconds: 90, failureThreshold: 3`.
- `nodeSelector` al nodo sin bug de Longhorn.
- **Bases:** `gam` (dataset) y `metabase_db` (app DB de Metabase, creada automáticamente por el bootstrap). Usuarios `metabase` (lectura del dataset) y `app_user` (DDL sobre `metabase_db`).

> **CAPTURA PARA EL INFORME:** `kubectl get sts,pvc` (MySQL 1/1 y PVC Bound 5Gi longhorn) y `kubectl describe pvc mysql-pvc` (StorageClass longhorn, Volume pvc-…).
> **CAPTURA PARA EL INFORME:** `kubectl get pod mysql-0 -o yaml` o `describe` (init container `remove-lost-found`, `nodeSelector`, probes con `mysqladmin ping`).

### 4.3 Importación del dataset

El dump `google-mobility.sql.gz` (4,0 MB comprimido) **no trae `CREATE DATABASE` ni `USE`**, por lo que se importa directamente a la base `gam` como tabla `mobility`:

```bash
gunzip -c google-mobility.sql.gz | kubectl exec -i mysql-0 -n vicenct-dev -- \
  sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql -uroot gam"
```

| Métrica | Valor |
|---|---|
| Filas importadas | **411.307** |
| Rango de fechas | 2020-02-15 → 2022-10-15 |
| Columnas | 15 (6 métricas de movilidad + regiones + fecha) |
| Cobertura | Todos los países; Argentina con provincias y departamentos |

> **CAPTURA PARA EL INFORME:** comando de importación con `kubectl exec` en ejecución.
> **CAPTURA PARA EL INFORME:** `SELECT COUNT(*) FROM gam.mobility` → 411307 (y `SELECT MIN(date), MAX(date)`).
> **CAPTURA PARA EL INFORME:** `SHOW DATABASES;` (gam + metabase_db) y `SELECT user, host FROM mysql.user;` (metabase, app_user).

### 4.4 Metabase

- Imagen `metabase/metabase:v0.62.13` (última estable al momento del despliegue).
- **Base interna en MySQL** (`MB_DB_TYPE=mysql`, schema `metabase_db`): la configuración de Metabase (usuarios, preguntas, dashboards) persiste en Longhorn, por lo que el setup se realiza **una única vez** aunque el pod se destruya.
- `MB_ADD_SAMPLE_DATASET=false`.

#### Probes (clave para el arranque)

Metabase ejecuta ~1184 migraciones Liquibase en su primer arranque (10-15 min). Las probes iniciales (`initialDelaySeconds: 60/300` + liveness con pocos fallos) **mataban el contenedor a mitad de migración**, corrompiendo el schema. La solución aplicada:

```yaml
startupProbe:        # protege el arranque lento: la liveness NO actúa hasta que responde
  httpGet: /api/health
  failureThreshold: 40   # 40 × 30s = 20 min de tolerancia
  periodSeconds: 30
livenessProbe:
  httpGet: /api/health
  initialDelaySeconds: 10   # pasa a actuar recién cuando startupProbe tuvo éxito
  periodSeconds: 30
  failureThreshold: 4
resources:
  requests: { memory: 1Gi, cpu: 500m }
  limits:   { memory: 4Gi, cpu: "2" }
```

Además: `nodeSelector` al nodo de MySQL (menor latencia por changeset) y 4Gi de RAM (la JVM usaba solo ~494 MB con el limit anterior).

> **CAPTURA PARA EL INFORME:** `kubectl get deploy metabase` (1/1 Available) y `kubectl get pod -l app=metabase -o wide` (Running, nodo `cluster-01-workers-4phg9-6w74j`).
> **CAPTURA PARA EL INFORME:** `kubectl describe pod <metabase>` (startupProbe con failureThreshold 40, resources 4Gi/2cpu, env `MB_DB_*`).
> **CAPTURA PARA EL INFORME:** `kubectl logs <metabase>` (migraciones Liquibase `Running 1184/1184 changesets` → `Metabase Initialization COMPLETE`).
> **CAPTURA PARA EL INFORME:** `curl http://localhost:3000/api/health` dentro del pod → `{"status":"ok"}`.

#### Setup automático (Job)

El **Job `metabase-setup-job`** (idempotente) automatiza el alta del usuario admin:

1. Espera `/api/health` = `{"status":"ok"}`.
2. Toma el `setup-token` de `/api/session/properties`.
3. Si el token existe (instancia sin configurar) → `POST /api/setup` con admin + preferencias.
4. Si el token es `null` (ya configurada) → termina sin hacer nada.

> **CAPTURA PARA EL INFORME:** logs del Job mostrando `Configuracion automatica completada.`
> **CAPTURA PARA EL INFORME:** `kubectl get job metabase-setup-job` (COMPLETIONS 1/1) y `kubectl describe job` (la primera corrida ejecutó el setup; las siguientes terminan sin crear nada — idempotencia).

#### Contenido (cards + dashboards) vía API

`scripts/metabase-setup.sh` crea/actualiza de forma idempotente la conexión a la base, las preguntas y los dashboards, y **archiva todo lo demás** (deja la instancia limpia):

| Pregunta | Tipo | Consulta |
|---|---|---|
| Google Mobility | Tabla | `mobility` filtrada a `country_region = Argentina` |
| Google Mobility - Evolución | Líneas | avg de retail/grocery/parks/workplaces por fecha (Argentina) |

| Dashboard | Contenido |
|---|---|
| Google Mobility - Dashboard | Card tabla (12×8) |
| Google Mobility - Dashboard Filtros | Card tabla (24×10) + gráfico (24×8) con filtros **Región 1** (`sub_region_1`), **Región 2** (`sub_region_2`) y **Fecha** (`date/range`), conectados a ambas cards |

> **CAPTURA PARA EL INFORME:** salida de `scripts/metabase-setup.sh` (conexión creada, cards 1-2, dashboards 2-3, archivado de lo demás).
> **CAPTURA PARA EL INFORME:** `GET /api/dashboard` → lista con los dashboards 2 y 3 (`Google Mobility - Dashboard`, `Google Mobility - Dashboard Filtros`).

#### Capturas en el navegador (resultado final)

> **CAPTURA PARA EL INFORME:** login de Metabase (`https://vicenct-metabase.my.kube.um.edu.ar/auth/login`).
> **CAPTURA PARA EL INFORME:** dashboard **Google Mobility - Dashboard** (tabla de Argentina).
> **CAPTURA PARA EL INFORME:** dashboard **Google Mobility - Dashboard Filtros** con un filtro aplicado (p. ej. Región 1 = Buenos Aires y rango de fechas acotado, tabla + gráfico actualizados).
> **CAPTURA PARA EL INFORME:** una pregunta (card) en modo editor mostrando la consulta a `gam.mobility`.
> **CAPTURA PARA EL INFORME:** Admin → Databases mostrando la conexión `gam` (MySQL, host `mysql-service`, user `metabase`).

### 4.5 Ingress NGINX

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: metabase-ingress
  namespace: vicenct-dev
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  ingressClassName: nginx     # obligatorio en RKE2 v1.35 (la anotación
                              # kubernetes.io/ingress.class está deprecada)
  rules:
    - host: vicenct-metabase.my.kube.um.edu.ar
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: metabase-service, port: { number: 3000 } } }
```

El DNS del laboratorio ya resuelve `vicenct-metabase.my.kube.um.edu.ar` → firewall UM (200.51.41.176) → Ingress. Se expone **solo Metabase**; MySQL permanece interno (ClusterIP).

> **CAPTURA PARA EL INFORME:** `kubectl get ingress` con CLASS nginx y ADDRESS; `curl https://vicenct-metabase.my.kube.um.edu.ar/api/health` → `{"status":"ok"}`.
> **CAPTURA PARA EL INFORME:** `kubectl get svc` (metabase-service y mysql-service ClusterIP).
> **CAPTURA PARA EL INFORME:** `nslookup vicenct-metabase.my.kube.um.edu.ar` (resolución DNS del laboratorio).

---

## 5. Reproducibilidad (bootstrap idempotente)

`scripts/bootstrap.sh` orquesta todo el ciclo en **un comando**:

```bash
./scripts/bootstrap.sh            # construir / verificar (idempotente)
./scripts/bootstrap.sh --destroy  # elimina SOLO los recursos del namespace
                                  # (nunca el namespace → preserva permisos Rancher)
```

| Paso | Acción |
|---|---|
| 1 | Aplica Secret + PVC + Service + StatefulSet MySQL |
| 2 | Espera MySQL Ready |
| 3 | Crea `metabase_db` + `app_user` (solo si faltan) |
| 4 | Importa el dataset (solo si `gam.mobility` está vacía) |
| 5 | Aplica Deployment + Service + Ingress de Metabase, espera rollout |
| 6 | Job de setup del admin (idempotente) |
| 7 | Contenido: conexión, cards, dashboards y archivado (idempotente) |

Al finalizar imprime un resumen con URL, dashboards, credenciales, health check y estado del stack.

### Prueba real de destrucción y reconstrucción

| Fase | Tiempo |
|---|---|
| Destrucción de recursos | ~20 s |
| MySQL + importación del dataset | ~4 min |
| Metabase (migraciones de primer arranque) | ~11 min |
| Job setup + contenido | ~1 min |
| **Total** | **~16 min, sin intervención** |

> **CAPTURA PARA EL INFORME:** salida completa del bootstrap con el resumen final (URL, dashboards, credenciales, health check, estado del stack).
> **CAPTURA PARA EL INFORME:** segunda ejecución del bootstrap (idempotente, sin cambios: `up to date`, importación omitida, resumen sin errores).

---

## 6. Persistencia (verificada)

Se borró el pod `mysql-0` (el StatefulSet lo recrea automáticamente) y se verificó que los datos sobreviven en Longhorn:

| Verificación | Antes | Después |
|---|---|---|
| UID del pod | `9d253bdd-…` | `b0a38fa5-…` (recreado) |
| Filas en `gam.mobility` | 411.307 | **411.307** |
| Bases | `gam`, `metabase_db` | idénticas |

> **CAPTURA PARA EL INFORME:** UIDs de pod antes/después y `SELECT COUNT(*)` idéntico.
> **CAPTURA PARA EL INFORME:** en Rancher UI: volumen Longhorn `pvc-c55aa02c-…` (mysql-pvc) con su estado Healthy.

---

## 7. Problemas encontrados y soluciones

| Problema | Causa | Solución |
|---|---|---|
| Metabase en CrashLoopBackOff (primer arranque) | Probes de liveness demasiado estrictas para el primer boot (~1184 migraciones, 10-15 min) | `startupProbe` con 20 min de tolerancia; la liveness actúa solo después |
| `Duplicate column name 'user_id'` / `Can't DROP 'entity_id'` | Migración interrumpida dejó el schema `metabase_db` inconsistente (changeset a medio aplicar) | Recrear el schema y migrar en una sola corrida limpia |
| Volumen que no formatea (`mke2fs ... in use by the system`) | Bug del nodo `cluster-01-workers2-kcnjb-c4wsf` con Longhorn | `nodeSelector` a un nodo sano |
| `lost+found` bloquea el datadir de MySQL | Comportamiento del formateo de volúmenes | Init container `remove-lost-found` |
| Ingress sin ADDRESS | Anotación `kubernetes.io/ingress.class` deprecada en RKE2 v1.35 | `spec.ingressClassName: nginx` |
| La base de datos del setup no se conectaba | En v0.62 el campo `database` del `POST /api/setup` no aplica | Conexión registrada vía `POST /api/database` en el script de contenido |
| `kubectl exec` corta al importar el dump | Timeout del canal stdin en el proxy de Rancher (dump de 57 MB sin comprimir) | La importación completa igual; verificación idempotente por `COUNT(*)` |
| Borrar el namespace rompía permisos Rancher | Los RBAC del usuario dependen del proyecto Rancher asociado al namespace | `--destroy` borra solo recursos, nunca el namespace |

> **CAPTURA PARA EL INFORME:** CrashLoopBackOff previo (`kubectl get pods` con RESTARTS alto) y logs con el error `Duplicate column name 'user_id'` / `Can't DROP 'entity_id'` (evidencia de los problemas de la sección 7).
> **CAPTURA PARA EL INFORME:** pod de Metabase Healthy tras el fix (startupProbe): `READY 1/1`, `RESTARTS 0`.

---

## 8. Recursos del repositorio

```
Caso3-Tele/
├── README.md                       # documentación de uso
├── informe.md                      # este informe
├── data/google-mobility.sql.gz     # dataset (4,0 MB)
├── k8s/
│   ├── secret.yaml                 # credenciales reales (NO versionado)
│   ├── secret.example.yaml         # plantilla para Git
│   ├── mysql-pvc.yaml              # PVC 5Gi longhorn
│   ├── mysql-service.yaml          # ClusterIP :3306
│   ├── mysql-statefulset.yaml      # MySQL 8.0 + initContainer + probes
│   ├── metabase-deployment.yaml    # Metabase v0.62.13 + startupProbe
│   ├── metabase-service.yaml       # ClusterIP :3000
│   ├── metabase-ingress.yaml       # Ingress nginx + host público
│   ├── metabase-setup-configmap.yaml  # script del Job de setup
│   └── metabase-setup-job.yaml     # Job idempotente (admin)
└── scripts/
    ├── bootstrap.sh                # despliegue completo en 1 comando
    └── metabase-setup.sh           # contenido: cards + dashboards + archivado
```

---

## 9. Conclusiones

- Se logró un despliegue **completamente automatizado y reproducible**: `./scripts/bootstrap.sh` reconstruye el stack completo (MySQL + dataset + Metabase + dashboards) en ~16 minutos sin intervención manual.
- La **persistencia** en Longhorn quedó demostrada: el borrado del pod no pierde datos, y la configuración de Metabase sobrevive porque su base interna vive en MySQL.
- El patrón `startupProbe` resultó esencial para aplicaciones de arranque lento (migraciones de primer boot) — la liveness debe proteger el *runtime*, no el *startup*.
- Las decisiones de infraestructura (nodeSelector por nodos defectuosos, `ingressClassName` explícito, Secret fuera de Git) responden a limitaciones reales del laboratorio y buenas prácticas de seguridad.

---

## Anexo: lista de capturas para el informe

**Terminal / kubectl (cluster `cluster-01`):**

1. `kubectl get nodes` — 17 nodos Ready, v1.35.4.
2. Namespace `vicenct-dev` con label de proyecto Rancher `p-gvv8n`.
3. `kubectl get storageclass` e `kubectl get ingressclass` (longhorn default, nginx).
4. `kubectl get secret mysql-secret -o yaml` (enmascarado) + `secret.example.yaml` + `.gitignore`.
5. `kubectl get sts,pvc` y `kubectl describe pvc mysql-pvc` — MySQL 1/1, PVC Bound 5Gi longhorn.
6. `kubectl describe pod mysql-0` — init container, nodeSelector, probes.
7. Comando de importación del dump en ejecución (`kubectl exec`).
8. `SELECT COUNT(*)` → 411307, `SELECT MIN/MAX(date)`, `SHOW DATABASES`, `SELECT user FROM mysql.user`.
9. `kubectl get deploy,pod` de Metabase (1/1 Available, nodo 4phg9-6w74j).
10. `kubectl describe pod <metabase>` — startupProbe 40×30s, resources, env `MB_DB_*`.
11. `kubectl logs <metabase>` — migraciones `Running 1184/1184` → `Initialization COMPLETE`.
12. `curl http://localhost:3000/api/health` → `{"status":"ok"}`.
13. Job de setup: `kubectl get job metabase-setup-job` (1/1) + logs `Configuracion automatica completada`.
14. Salida de `scripts/metabase-setup.sh` + `GET /api/dashboard` (dashboards 2 y 3).
15. `kubectl get ingress,svc` — CLASS nginx, ADDRESS, ClusterIPs.
16. `nslookup vicenct-metabase.my.kube.um.edu.ar` + `curl https://…/api/health` → HTTP 200.
17. Bootstrap: salida completa (resumen final) y segunda corrida idempotente.
18. Persistencia: UID del pod antes/después + COUNT(*) idéntico.
19. Evidencia de los problemas: CrashLoopBackOff con `Duplicate column name 'user_id'` / `Can't DROP 'entity_id'` y pod Healthy tras el fix (`RESTARTS 0`).

**Rancher UI:**

20. Proyecto `p-gvv8n` → Workloads con `mysql-0` y `metabase-*` Running.
21. Volumen Longhorn `pvc-c55aa02c-…` (mysql-pvc) Healthy.
22. Ingress `metabase-ingress` con el host público.

**Navegador (https://vicenct-metabase.my.kube.um.edu.ar):**

23. Login de Metabase.
24. Dashboard **Google Mobility - Dashboard** (tabla Argentina).
25. Dashboard **Google Mobility - Dashboard Filtros** con filtro aplicado (Región 1 + rango de fechas).
26. Card en modo editor (consulta a `gam.mobility`).
27. Admin → Databases (conexión `gam`, host `mysql-service`).