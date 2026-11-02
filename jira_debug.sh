#!/bin/bash
JIRA_BASE_URL="https://ТВОЙ_JIRA.com"   # ← сюда
JIRA_TOKEN="ТВОЙ_ТОКЕН"                  # ← сюда
EPIC_KEY="QBS-XXX"                       # ← сюда реальный ключ эпика

echo "═══════════════════════════════════════"
echo "🔍 Changelog для: ${EPIC_KEY}"
echo "═══════════════════════════════════════"

http_code=$(curl -s \
  -o /tmp/cl_debug.json \
  -w "%{http_code}" \
  -X GET \
  -H "Authorization: Bearer ${JIRA_TOKEN}" \
  -H "Accept: application/json" \
  "${JIRA_BASE_URL}/rest/api/2/issue/${EPIC_KEY}/changelog?startAt=0&maxResults=10")

echo "HTTP: ${http_code}"

if [[ "${http_code}" != "200" ]]; then
  echo "❌ Ошибка запроса — сырой ответ:"
  cat /tmp/cl_debug.json
  exit 1
fi

echo "── Структура ответа (верхний уровень) ──"
jq '{total, maxResults, startAt, values_count: (.values | length)}' /tmp/cl_debug.json

echo ""
echo "── Первая запись changelog (сырая) ──"
jq '.values[0]' /tmp/cl_debug.json

echo ""
echo "── Все items первой записи ──"
jq '.values[0].items[]' /tmp/cl_debug.json

echo ""
echo "── Только статусные переходы (все записи) ──"
jq '.values[] | .created as $d | .items[] | select(.field == "status") | {date: $d, field: .field, from: .fromString, to: .toString}' /tmp/cl_debug.json

echo ""
echo "── Тест jq выражения из скрипта ──"
echo "[]" > /tmp/cl_acc.json
jq -s '
  .[0] + [
    .[1].values[] |
    .created as $date |
    .items[] |
    select(.field == "status") |
    {date: $date, to: ."toString"}
  ]' /tmp/cl_acc.json /tmp/cl_debug.json

rm -f /tmp/cl_debug.json /tmp/cl_acc.json
