#!/bin/bash
JIRA_BASE_URL=""
JIRA_TOKEN=""
EPIC_KEY="${1:-QBS-123}"

echo "═══════════════════════════════════════"
echo "🔍 Changelog для: ${EPIC_KEY}"
echo "═══════════════════════════════════════"

curl -s \
  -X GET \
  -H "Authorization: Bearer ${JIRA_TOKEN}" \
  -H "Accept: application/json" \
  "${JIRA_BASE_URL}/rest/api/2/issue/${EPIC_KEY}/changelog?startAt=0&maxResults=10" \
  -o /tmp/cl_debug.json

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