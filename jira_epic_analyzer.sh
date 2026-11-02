#!/bin/bash
# ── Конфигурация ──────────────────────────────────────────────
JIRA_BASE_URL=""
JIRA_TOKEN=""
JQL=""
MAX_RESULTS=50
DELAY_EPIC=0.1
DELAY_CHILD=0.05
CSV_FILE="jira_epic_analysis.csv"
BITBUCKET_SERVICE="STASH"
CHILD_KEY_PREFIX="QBS"

# ── Проверки ──────────────────────────────────────────────────
if ! command -v jq &> /dev/null; then
  echo "❌ jq не установлен"; exit 1
fi
if [[ -z "${JQL}" ]]; then
  echo "❌ JQL не задан"; exit 1
fi

# ── Функция: репозитории задачи ───────────────────────────────
get_repos() {
  local key="${1}"
  local repos=""

  # Шаг 1: remotelinks — берём только git URL
  local http_code
  http_code=$(curl -s \
    -o /tmp/ea_remotelinks.json \
    -w "%{http_code}" \
    -X GET \
    -H "Authorization: Bearer ${JIRA_TOKEN}" \
    -H "Accept: application/json" \
    "${JIRA_BASE_URL}/rest/api/2/issue/${key}/remotelink")
  sleep "${DELAY_CHILD}"

  echo "      remotelinks HTTP: ${http_code}" >&2

  if [[ "${http_code}" == "200" ]]; then
    local count
    count=$(jq '. | length' /tmp/ea_remotelinks.json)
    echo "      remotelinks найдено: ${count}" >&2

    if [[ "${count}" -gt 0 ]]; then
      repos=$(jq -r '.[].object.url // ""' /tmp/ea_remotelinks.json \
        | grep -v '^$' \
        | grep -i "git" \
        | sed 's|.*/\([^/]*\)/-/merge_requests.*|\1|' \
        | sort -u \
        | tr '\n' ',' \
        | sed 's/,$//')
      echo "      репо из git: ${repos:-пусто}" >&2
    fi
  fi

  # Шаг 2: если пусто — проверяем Bitbucket через fields=*all
  if [[ -z "${repos}" ]]; then
    echo "      remotelinks пусто — проверяем Bitbucket..." >&2

    http_code=$(curl -s \
      -o /tmp/ea_issue.json \
      -w "%{http_code}" \
      -X GET \
      -H "Authorization: Bearer ${JIRA_TOKEN}" \
      -H "Accept: application/json" \
      "${JIRA_BASE_URL}/rest/api/2/issue/${key}?fields=*all")
    sleep "${DELAY_CHILD}"

    echo "      issue HTTP: ${http_code}" >&2

    if [[ "${http_code}" == "200" ]]; then
      local has_bb
      has_bb=$(jq -r '.. | strings | select(test("itbucket"; "i"))' /tmp/ea_issue.json | head -1)
      if [[ -n "${has_bb}" ]]; then
        echo "      Bitbucket обнаружен → ${BITBUCKET_SERVICE}" >&2
        repos="${BITBUCKET_SERVICE}"
      else
        echo "      Bitbucket не найден" >&2
      fi
    fi
  fi

  echo "${repos}"
}

# ── Функция: даты переходов статусов эпика ───────────────────
get_status_dates() {
  local key="${1}"

  local cl_http
  cl_http=$(curl -s \
    -o /tmp/ea_cl_page.json \
    -w "%{http_code}" \
    -X GET \
    -H "Authorization: Bearer ${JIRA_TOKEN}" \
    -H "Accept: application/json" \
    "${JIRA_BASE_URL}/rest/api/2/issue/${key}?expand=changelog&fields=changelog")
  sleep "${DELAY_CHILD}"

  echo "    changelog HTTP: ${cl_http}" >&2

  if [[ "${cl_http}" != "200" ]]; then
    echo "    ⚠️  Ошибка changelog" >&2
    echo ";;;;;;";
    return
  fi

  # Извлекаем статусные переходы из histories
  jq '[
    .changelog.histories[] |
    .created as $date |
    .items[] |
    select(.field == "status") |
    {date: $date, to: ."toString"}
  ]' /tmp/ea_cl_page.json > /tmp/ea_transitions.json

  echo "    Переходов статусов найдено: $(jq 'length' /tmp/ea_transitions.json)" >&2

  # Первые вхождения
  local d_ready d_refinement d_to_dev d_in_dev
  d_ready=$(jq -r '[.[] | select(.to | ascii_downcase == "ready")] | first | .date // "" | .[:10]' /tmp/ea_transitions.json)
  d_refinement=$(jq -r '[.[] | select(.to | ascii_downcase == "refinement")] | first | .date // "" | .[:10]' /tmp/ea_transitions.json)
  d_to_dev=$(jq -r '[.[] | select(.to | ascii_downcase == "to dev")] | first | .date // "" | .[:10]' /tmp/ea_transitions.json)
  d_in_dev=$(jq -r '[.[] | select(.to | ascii_downcase == "in dev")] | first | .date // "" | .[:10]' /tmp/ea_transitions.json)

  # Последние вхождения
  local d_rtd d_released
  d_rtd=$(jq -r '[.[] | select(.to | ascii_downcase == "ready to deploy")] | last | .date // "" | .[:10]' /tmp/ea_transitions.json)
  d_released=$(jq -r '[.[] | select(.to | ascii_downcase == "released")] | last | .date // "" | .[:10]' /tmp/ea_transitions.json)

  echo "    Ready: ${d_ready} | Refinement: ${d_refinement} | To Dev: ${d_to_dev} | In Dev: ${d_in_dev} | RTD: ${d_rtd} | Released: ${d_released}" >&2

  echo "${d_ready};${d_refinement};${d_to_dev};${d_in_dev};${d_rtd};${d_released}"
}

# ── Заголовок CSV ─────────────────────────────────────────────
echo "URL эпика;Story Points;Дата создания;Ready;Refinement;To Dev;In Dev;Ready to Deploy;Released;Репозитории" > "${CSV_FILE}"

# ── Основной цикл с пагинацией ────────────────────────────────
start_at=0
total=1

while [[ "${start_at}" -lt "${total}" ]]; do
  echo "════════════════════════════════════════════════════════"
  echo "📄 Запрашиваем агрегаты: startAt=${start_at}"

  body=$(jq -n \
    --arg     jql        "${JQL}" \
    --argjson maxResults "${MAX_RESULTS}" \
    --argjson startAt    "${start_at}" \
    '{
      jql:        $jql,
      maxResults: $maxResults,
      startAt:    $startAt,
      fields:     ["summary", "customfield_34152", "created"]
    }')

  http_code=$(curl -s \
    -o /tmp/ea_search.json \
    -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${JIRA_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${body}" \
    "${JIRA_BASE_URL}/rest/api/2/search")
  sleep "${DELAY_EPIC}"

  echo "📥 search HTTP: ${http_code}"

  if [[ "${http_code}" != "200" ]]; then
    echo "❌ Ошибка поиска: HTTP ${http_code}"
    jq '.' /tmp/ea_search.json
    exit 1
  fi

  total=$(jq '.total' /tmp/ea_search.json | xargs)
  count=$(jq '.issues | length' /tmp/ea_search.json | xargs)
  echo "📊 Всего агрегатов: ${total} | Получено: ${count}"

  for i in $(seq 0 $((count - 1))); do
    epic_key=$(jq -r ".issues[${i}].key" /tmp/ea_search.json)
    summary=$(jq -r ".issues[${i}].fields.summary // \"—\"" /tmp/ea_search.json)
    story_points=$(jq -r ".issues[${i}].fields.customfield_34152.value // \"\"" /tmp/ea_search.json)
    created=$(jq -r ".issues[${i}].fields.created // \"\" | .[:10]" /tmp/ea_search.json)

    echo "────────────────────────────────────────────────────────"
    echo "📋 Агрегат: ${epic_key} | ${summary}"
    echo "   SP: ${story_points} | Создана: ${created}"

    echo "  📅 Получаем даты статусов..."
    status_dates=$(get_status_dates "${epic_key}")

    epic_url="${JIRA_BASE_URL}/browse/${epic_key}"
    all_repos=""

    # ── Дочерние задачи через Epic Link ───────────────────────
    child_body=$(jq -n \
      --arg key "${epic_key}" \
      '{
        jql:        ("\"Epic Link\" = \"" + $key + "\""),
        maxResults: 100,
        fields:     ["summary"]
      }')

    child_http=$(curl -s \
      -o /tmp/ea_children.json \
      -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${JIRA_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "${child_body}" \
      "${JIRA_BASE_URL}/rest/api/2/search")
    sleep "${DELAY_EPIC}"

    echo "  📥 children HTTP: ${child_http}"

    if [[ "${child_http}" != "200" ]]; then
      echo "  ⚠️  Ошибка получения дочерних задач"
      echo "${epic_url};${story_points};${created};${status_dates};" >> "${CSV_FILE}"
      continue
    fi

    child_count=$(jq '.issues | length' /tmp/ea_children.json | xargs)
    echo "  📦 Дочерних задач: ${child_count}"

    if [[ "${child_count}" -eq 0 ]]; then
      echo "  ⚠️  Дочерние задачи не найдены"
      echo "${epic_url};${story_points};${created};${status_dates};" >> "${CSV_FILE}"
      continue
    fi

    # ── Репозитории по каждой дочерней задаче ─────────────────
    for j in $(seq 0 $((child_count - 1))); do
      child_key=$(jq -r ".issues[${j}].key" /tmp/ea_children.json)
      [[ "${child_key}" != ${CHILD_KEY_PREFIX}-* ]] && continue
      child_summary=$(jq -r ".issues[${j}].fields.summary // \"—\"" /tmp/ea_children.json)
      echo "  ↳ ${child_key} | ${child_summary}"

      repos=$(get_repos "${child_key}")

      if [[ -n "${repos}" ]]; then
        if [[ -z "${all_repos}" ]]; then
          all_repos="${repos}"
        else
          all_repos=$(echo "${all_repos},${repos}" \
            | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
        fi
      fi
    done

    echo "  📦 Итого репозитории по агрегату: ${all_repos:-пусто}"
    echo "${epic_url};${story_points};${created};${status_dates};${all_repos}" >> "${CSV_FILE}"
  done

  start_at=$((start_at + count))
done

# ── Очистка ───────────────────────────────────────────────────
rm -f /tmp/ea_search.json /tmp/ea_children.json /tmp/ea_remotelinks.json /tmp/ea_issue.json /tmp/ea_transitions.json /tmp/ea_transitions_new.json /tmp/ea_cl_page.json

echo ""
echo "════════════════════════════════════════════════════════"
echo "✅ Готово! Результат: ${CSV_FILE}"
