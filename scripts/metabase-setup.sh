#!/usr/bin/env bash
set -euo pipefail

# Uso: ./metabase-setup.sh <FE_URL> <DB_HOST> <DB_PASS> <ADMIN_EMAIL> <ADMIN_PASS>
# Ejemplo:
#   ./metabase-setup.sh https://vicenct-metabase.my.kube.um.edu.ar mysql-service ce46636f0b6daf2fb32f0602 admin@proyecto.com 1c194f5d4edaf4843e1e559c

FE_URL="${1:?}"; DB_HOST="${2:?}"; DB_PASS="${3:?}"; ADMIN_EMAIL="${4:?}"; ADMIN_PASS="${5:?}"

DB_NAME="gam"
DB_USER="metabase"
CARD_NAME="Google Mobility"
GRAPH_CARD_NAME="Google Mobility - Evolución"
DASH_NAME="Google Mobility - Dashboard"
DASH_FILTER_NAME="Google Mobility - Dashboard Filtros"

CURL="curl -s -f -m 15"

# 1) Espera a que Metabase este levantado
echo "Esperando a que Metabase responda..."
ok=0
for i in $(seq 1 60); do
  if $CURL -o /dev/null "${FE_URL}/api/health"; then
    ok=1
    break
  fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "Metabase no respondió a tiempo"; exit 1; }
echo "Metabase arriba."

# 2) Obtener sesion de admin
echo "Autenticando..."
TOKEN="$($CURL "${FE_URL}/api/session" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" \
  | jq -r '.id // empty')"
[ -n "$TOKEN" ] || { echo "No se pudo autenticar con Metabase"; exit 1; }
echo "Sesión obtenida."

# 3) Conexion a la base MySQL (idempotente: reusa la existente si ya esta)
echo "Conexión a la base MySQL (idempotente)..."
DB_ID="$($CURL "${FE_URL}/api/database" \
  -H "X-Metabase-Session: ${TOKEN}" \
  | jq -r '.data[] | select(.name=="Google Mobility") | .id' | head -1)"
if [ -z "$DB_ID" ]; then
  DB_ID="$($CURL "${FE_URL}/api/database" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d "{\"name\":\"Google Mobility\",\"engine\":\"mysql\",\"details\":{\"host\":\"${DB_HOST}\",\"port\":3306,\"dbname\":\"${DB_NAME}\",\"user\":\"${DB_USER}\",\"password\":\"${DB_PASS}\"}}" \
    | jq -r '.id // empty')"
fi
[ -n "$DB_ID" ] || { echo "No se pudo crear la conexión a MySQL"; exit 1; }
echo "Conexión a MySQL lista (id=${DB_ID})."

# 4) Archivar contenido que no sea el nuestro (cards, dashboards, colecciones)
echo "Archivando contenido de muestra..."
for kind in card dashboard collection; do
  ids=$( { $CURL "${FE_URL}/api/${kind}?limit=1000" \
    -H "X-Metabase-Session: ${TOKEN}" || echo '[]'; } \
    | jq -r --arg card "$CARD_NAME" --arg graph "$GRAPH_CARD_NAME" --arg dash "$DASH_NAME" --arg dash_filter "$DASH_FILTER_NAME" \
      '.[]? | select(.name != $card and .name != $graph and .name != $dash and .name != $dash_filter) | .id' )
  for id in $ids; do
    case $kind in
      card)       $CURL -X PUT "${FE_URL}/api/card/${id}" \
                  -H 'Content-Type: application/json' \
                  -H "X-Metabase-Session: ${TOKEN}" \
                  -d '{"archived":true}' > /dev/null || true ;;
      dashboard)  $CURL -X PUT "${FE_URL}/api/dashboard/${id}" \
                  -H 'Content-Type: application/json' \
                  -H "X-Metabase-Session: ${TOKEN}" \
                  -d '{"archived":true}' > /dev/null || true ;;
      collection) $CURL -X PUT "${FE_URL}/api/collection/${id}" \
                  -H 'Content-Type: application/json' \
                  -H "X-Metabase-Session: ${TOKEN}" \
                  -d '{"archived":true}' > /dev/null || true ;;
    esac
  done
done

# Archivar bases de datos de muestra (todo lo que no sea la nuestra)
for dbid in $( { $CURL "${FE_URL}/api/database" \
  -H "X-Metabase-Session: ${TOKEN}" || echo '{"data":[]}'; } \
  | jq -r '.data[] | select(.id != '"${DB_ID}"') | .id' ); do
  $CURL -X DELETE "${FE_URL}/api/database/${dbid}" \
    -H "X-Metabase-Session: ${TOKEN}" > /dev/null || true
done
echo "Contenido de muestra archivado."

# 5) Asegurar el card tabla (query builder/MBQL) - "Google Mobility"
echo "Asegurando card tabla..."
CARD_JSON=$(jq -n \
  --arg name "$CARD_NAME" \
  --argjson database "$DB_ID" \
  '{name:$name,
    display:"table",
    description:"Dataset Google Mobility (mobility)",
    dataset_query:{database:$database,
                   type:"query",
                   query:{"source-table":9,
                          fields:[["field",73,null],["field",74,null],["field",75,null],["field",76,null],["field",77,null],["field",80,null],["field",81,null],["field",82,null],["field",83,null],["field",84,null],["field",85,null],["field",86,null]],
                          filter:["=",["field",73,null],"Argentina"]}},
    visualization_settings:{}}')
CARD_ID="$($CURL "${FE_URL}/api/card?limit=1000" \
  -H "X-Metabase-Session: ${TOKEN}" \
  | jq -r --arg name "$CARD_NAME" '.[] | select(.name==$name) | .id' | head -1)"
if [ -z "$CARD_ID" ]; then
  CARD_ID="$($CURL "${FE_URL}/api/card" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d "$CARD_JSON" \
    | jq -r '.id // empty')"
else
  $CURL -X PUT "${FE_URL}/api/card/${CARD_ID}" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d "$CARD_JSON" > /dev/null
fi
[ -n "$CARD_ID" ] || { echo "No se pudo crear el card tabla"; exit 1; }
echo "Card tabla listo (id=${CARD_ID})."

# 5b) Asegurar el card gráfico (query builder/MBQL) - "Google Mobility - Evolución"
echo "Asegurando card gráfico..."
GRAPH_CARD_JSON=$(jq -n \
  --arg name "$GRAPH_CARD_NAME" \
  --argjson database "$DB_ID" \
  '{name:$name,
    archived:false,
    display:"line",
    description:"Evolución temporal promedio de retail, grocery, parks y workplaces",
    dataset_query:{database:$database,
                   type:"query",
                   query:{"source-table":9,
                          filter:["=",["field",73,null],"Argentina"],
                          aggregation:[["avg",["field",81,null]],["avg",["field",82,null]],["avg",["field",83,null]],["avg",["field",85,null]]],
                          breakout:[["field",80,null]],
                          "order-by":[["asc",["field",80,null]]]}},
    visualization_settings:{}}')
GRAPH_CARD_ID="$($CURL "${FE_URL}/api/card?limit=1000" \
  -H "X-Metabase-Session: ${TOKEN}" \
  | jq -r --arg name "$GRAPH_CARD_NAME" '.[] | select(.name==$name) | .id' | head -1)"
if [ -z "$GRAPH_CARD_ID" ]; then
  GRAPH_CARD_ID="$($CURL "${FE_URL}/api/card" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d "$GRAPH_CARD_JSON" \
    | jq -r '.id // empty')"
else
  $CURL -X PUT "${FE_URL}/api/card/${GRAPH_CARD_ID}" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d "$GRAPH_CARD_JSON" > /dev/null
fi
[ -n "$GRAPH_CARD_ID" ] || { echo "No se pudo crear el card gráfico"; exit 1; }
echo "Card gráfico listo (id=${GRAPH_CARD_ID})."

# 6) Asegurar el dashboard "Google Mobility - Dashboard" con el card tabla
echo "Asegurando dashboard principal..."
DASH_ID="$($CURL "${FE_URL}/api/dashboard?limit=1000" \
  -H "X-Metabase-Session: ${TOKEN}" \
  | jq -r --arg name "$DASH_NAME" '.[] | select(.name==$name) | .id' | head -1)"
if [ -z "$DASH_ID" ]; then
  DASH_ID="$($CURL "${FE_URL}/api/dashboard" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d '{"name":"'"${DASH_NAME}"'"}' \
    | jq -r '.id // empty')"
else
  $CURL -X PUT "${FE_URL}/api/dashboard/${DASH_ID}" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d '{"archived":false}' > /dev/null
fi
[ -n "$DASH_ID" ] || { echo "No se pudo crear el dashboard"; exit 1; }

HAS_CARD="$($CURL "${FE_URL}/api/dashboard/${DASH_ID}" \
  -H "X-Metabase-Session: ${TOKEN}" \
  | jq -r '(.dashcards // []) | length')"
if [ "${HAS_CARD}" = "0" ] || [ -z "${HAS_CARD}" ]; then
  $CURL -X PUT "${FE_URL}/api/dashboard/${DASH_ID}" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d '{"dashcards":[{"id":-1,"card_id":'"${CARD_ID}"',"col":0,"row":0,"size_x":12,"size_y":8,"series":[],"visualization_settings":{},"parameter_mappings":[]}]}' > /dev/null
fi
echo "Dashboard principal listo (id=${DASH_ID})."

# 7) Asegurar el dashboard con filtros "Google Mobility - Dashboard Filtros"
echo "Asegurando dashboard con filtros..."
DASH_FILTER_ID="$($CURL "${FE_URL}/api/dashboard?limit=1000" \
  -H "X-Metabase-Session: ${TOKEN}" \
  | jq -r --arg name "$DASH_FILTER_NAME" '.[] | select(.name==$name) | .id' | head -1)"
if [ -z "$DASH_FILTER_ID" ]; then
  DASH_FILTER_ID="$($CURL "${FE_URL}/api/dashboard" \
    -H 'Content-Type: application/json' \
    -H "X-Metabase-Session: ${TOKEN}" \
    -d '{"name":"'"${DASH_FILTER_NAME}"'"}' \
    | jq -r '.id // empty')"
fi
[ -n "$DASH_FILTER_ID" ] || { echo "No se pudo crear el dashboard filtrable"; exit 1; }

DASH_FILTER_STATE="$($CURL "${FE_URL}/api/dashboard/${DASH_FILTER_ID}" \
  -H "X-Metabase-Session: ${TOKEN}")"
TABLE_DASHCARD_ID="$(echo "$DASH_FILTER_STATE" | jq -r '.dashcards[]? | select(.card_id=='"${CARD_ID}"') | .id' | head -1)"
GRAPH_DASHCARD_ID="$(echo "$DASH_FILTER_STATE" | jq -r '.dashcards[]? | select(.card_id=='"${GRAPH_CARD_ID}"') | .id' | head -1)"
[ -n "$TABLE_DASHCARD_ID" ] || TABLE_DASHCARD_ID=-1
[ -n "$GRAPH_DASHCARD_ID" ] || GRAPH_DASHCARD_ID=-2

DASH_FILTER_JSON='{"name":"'"${DASH_FILTER_NAME}"'","parameters":[{"id":"sub_region_1","name":"Región 1","slug":"sub_region_1","type":"category","target":["dimension",["field",74,null]]},{"id":"sub_region_2","name":"Región 2","slug":"sub_region_2","type":"category","target":["dimension",["field",75,null]]},{"id":"fecha","name":"Fecha","slug":"fecha","type":"date/range","target":["dimension",["field",80,null]]}],"dashcards":[{"id":'"${TABLE_DASHCARD_ID}"',"card_id":'"${CARD_ID}"',"col":0,"row":0,"size_x":24,"size_y":10,"series":[],"visualization_settings":{},"parameter_mappings":[{"card_id":'"${CARD_ID}"',"parameter_id":"sub_region_1","target":["dimension",["field",74,null]]},{"card_id":'"${CARD_ID}"',"parameter_id":"sub_region_2","target":["dimension",["field",75,null]]},{"card_id":'"${CARD_ID}"',"parameter_id":"fecha","target":["dimension",["field",80,null]]}]},{"id":'"${GRAPH_DASHCARD_ID}"',"card_id":'"${GRAPH_CARD_ID}"',"col":0,"row":10,"size_x":24,"size_y":8,"series":[],"visualization_settings":{},"parameter_mappings":[{"card_id":'"${GRAPH_CARD_ID}"',"parameter_id":"sub_region_1","target":["dimension",["field",74,null]]},{"card_id":'"${GRAPH_CARD_ID}"',"parameter_id":"sub_region_2","target":["dimension",["field",75,null]]},{"card_id":'"${GRAPH_CARD_ID}"',"parameter_id":"fecha","target":["dimension",["field",80,null]]}]}]}'

$CURL -X PUT "${FE_URL}/api/dashboard/${DASH_FILTER_ID}" \
  -H 'Content-Type: application/json' \
  -H "X-Metabase-Session: ${TOKEN}" \
  -d "$DASH_FILTER_JSON" > /dev/null
echo "Dashboard con filtros listo (id=${DASH_FILTER_ID})."

echo "SETUP COMPLETO: ${FE_URL} (card=${CARD_ID}, card_graf=${GRAPH_CARD_ID}, dashboard=${DASH_ID}, dashboard_filtros=${DASH_FILTER_ID})"
