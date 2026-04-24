#!/bin/bash

# ==============================================================================
# НАЗВАНИЕ: ALD Pro Client Checker
# ВЕРСИЯ: 2.6.1 (Актуализировано под ALD Pro 3.2.0)
# ==============================================================================
# ТИПЫ СТАТУСОВ (ROLE_OR_STATE):
# 1. DOMAIN_CONTROLLER  - Контроллер домена (DC)
# 2. SUB:[РОЛИ]         - Сервер подсистемы (DHCP, DNS, REPO и т.д.)
# 3. configured         - Штатный клиент в домене
# 4. ENROLLED(manual)   - Хост в домене (найден keytab), статус определен косвенно
# ------------------------------------------------------------------------------
# АКТУАЛЬНОСТЬ: Версия 3.2.0 является текущим мажорным релизом.
# ==============================================================================

VERSION_ID="2.6.1"

# Функция очистки истории (для ключа -S)
cleanup_history() {
    # Удаляем последнюю строку из файла .bash_history
    if [[ -f "$HOME/.bash_history" ]]; then
        sed -i '$d' "$HOME/.bash_history"
        # Синхронизируем текущую сессию
        history -d $(history | tail -n 1 | awk '{print $1}') 2>/dev/null
    fi
}

# Функция проверки Kerberos-билета (необходим для опроса каталога IPA)
check_kerberos() {
    if ! klist -s; then
        echo "ОШИБКА: Нет активного билета Kerberos. Выполните 'kinit admin'."
        exit 1
    fi
}

# Определение локальной версии сервера ALD Pro
get_server_version() {
    local ver
    ver=$(dpkg-query -W -f='${Version}' aldpro-server 2>/dev/null)
    if [[ -n "$ver" ]]; then
        echo "--- Локальный сервер ALD Pro v$ver (Актуальный стандарт 3.2.0+) ---"
    fi
}

# Справка (Usage)
usage() {
    echo "Использование: $0 [КЛЮЧИ]"
    echo ""
    echo "Параметры:"
    echo "  -v              Показать версию скрипта"
    echo "  -l              Режим списка (FQDN + IP) без SSH опроса"
    echo "  -n              Clean mode: без заголовков и служебной информации"
    echo "  -S              Silent mode: удаление команды запуска из истории bash"
    echo "  -f <шаблон>     Фильтр имен через регулярные выражения (grep -E)"
    echo "  -H <хост>       Проверка только одного конкретного FQDN"
    echo "  -u <логин>      SSH пользователь"
    echo "  -p <пароль>     SSH пароль (обязательно в одинарных кавычках '')"
    echo ""
    echo "СОВЕТ ПО БЕЗОПАСНОСТИ:"
    echo "  Для полной скрытости вводите пробел ПЕРЕД всей командой."
    exit 1
}

# --- Инициализация и парсинг ---
if [ $# -eq 0 ]; then usage; fi

for arg in "$@"; do 
    [[ "$arg" == "-v" ]] && echo "Version $VERSION_ID" && exit 0
done

LIST_ONLY=false; NO_HEADER=false; SILENT_MODE=false; FILTER=""; SINGLE_HOST=""; USERNAME=""; PASSWORD=""

while getopts ":lnSf:H:u:p:v" opt; do
    case "$opt" in
        l) LIST_ONLY=true ;;
        n) NO_HEADER=true ;;
        S) SILENT_MODE=true ;;
        f) FILTER=$OPTARG ;;
        H) SINGLE_HOST=$OPTARG ;;
        u) USERNAME=$OPTARG ;;
        p) PASSWORD=$OPTARG ;;
        v) echo "Version $VERSION_ID"; exit 0 ;;
        *) usage ;;
    esac
done

# --- ОСНОВНАЯ ЛОГИКА ---

# Проверка прав доступа к каталогу
check_kerberos

# Вывод версии (если не задан -n)
[[ "$NO_HEADER" = false ]] && get_server_version

# Сбор списка хостов
if [[ -n "$SINGLE_HOST" ]]; then
    RAW_HOSTS="$SINGLE_HOST"
else
    RAW_HOSTS=$(ipa host-find --raw 2>/dev/null | grep -E "^  fqdn:|^fqdn:" | awk '{print $2}')
    [[ -z "$RAW_HOSTS" ]] && RAW_HOSTS=$(ipa host-find 2>/dev/null | grep -E "Host name:|Имя хоста:" | awk '{print $3}')
fi

[[ -z "$RAW_HOSTS" ]] && echo "Ошибка: Список хостов пуст." && exit 1

# Подготовка данных (Фильтрация и получение IP)
HOSTS_DATA=""
while read -r HOST; do
    [[ -z "$HOST" ]] && continue
    if [[ -n "$FILTER" && -z "$SINGLE_HOST" ]]; then
        if ! echo "$HOST" | grep -qE "$FILTER"; then continue; fi
    fi
    IP=$(getent hosts "$HOST" | awk '{print $1}')
    HOSTS_DATA+="$HOST ${IP:-no_ip}"$'\n'
done <<< "$RAW_HOSTS"

# Режим 1: Вывод списка (без SSH)
if [[ "$LIST_ONLY" = true || -z "$USERNAME" || -z "$PASSWORD" ]]; then
    if [[ "$NO_HEADER" = false ]]; then
        printf "%-45s %-15s\n" "FQDN_HOST" "IP_ADDRESS"
        echo "----------------------------------------------------------------"
    fi
    echo -e "$HOSTS_DATA" | while read -r h ip; do
        [[ -n "$h" ]] && printf "%-45s %-15s\n" "$h" "$ip"
    done
    [[ "$SILENT_MODE" = true ]] && cleanup_history
    exit 0
fi

# Режим 2: Полноценное SSH сканирование
[[ ! -x $(command -v sshpass) ]] && echo "Ошибка: установите sshpass" && exit 1

if [[ "$NO_HEADER" = false ]]; then
    printf "%-45s %-25s %-25s\n" "FQDN_HOST" "CLIENT_VERSION" "ROLE_OR_STATE"
    echo "-------------------------------------------------------------------------------------------------------------------"
fi

# Цикл опроса
echo -e "$HOSTS_DATA" | awk '{print $1}' | while read -r HOST; do
    [[ -z "$HOST" ]] && continue
    
    # -n запрещает ssh "поглощать" stdin цикла
    RESULT=$(sshpass -p "$PASSWORD" ssh -n -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no \
        -o BatchMode=no \
        "$USERNAME@$HOST" "
        
        # 1. Сбор версии пакета
        V=\$(dpkg-query -W -f='\${Version}' aldpro-client 2>/dev/null || echo 'not_installed')
        
        # 2. Определение роли и статуса
        S=''
        if [ -f '/etc/aldpro/server/server.json' ] || [ -d '/etc/ipa/html' ]; then
            S='DOMAIN_CONTROLLER'
        else
            # Детекция подсистем через пакетный менеджер
            SUBSYS=\$(dpkg -l | grep -E 'aldpro-subsystem-|aldpro-server-' | awk '{print \$2}' | sed -E 's/aldpro-(subsystem|server)-//' | tr '\\\n' ',' | sed 's/,\$//')
            
            if [ -n \"\$SUBSYS\" ]; then
                S=\"SUB:[\${SUBSYS^^}]\"
            elif command -v aldpro-client-join-state &>/dev/null; then
                S=\$(aldpro-client-join-state 2>/dev/null | grep 'State:' | awk '{print \$2}')
            elif command -v ipa-client-status &>/dev/null; then
                S=\$(ipa-client-status 2>/dev/null | grep 'Enrolled:' | awk '{print \$2}')
            elif [ -f '/etc/krb5.keytab' ]; then
                S='ENROLLED(manual)'
            else
                S='NOT_IN_DOMAIN'
            fi
        fi
        echo \"\$V|\${S:-unknown}\"
    " 2>/dev/null)

    if [[ $? -eq 0 ]]; then
        V_REMOTE=$(echo "$RESULT" | cut -d'|' -f1)
        S_REMOTE=$(echo "$RESULT" | cut -d'|' -f2)
        printf "%-45s %-25s %-25s\n" "$HOST" "$V_REMOTE" "$S_REMOTE"
    else
        printf "%-45s %-25s %-25s\n" "$HOST" "UNREACHABLE" "N/A"
    fi
done

# Очистка следов
[[ "$SILENT_MODE" = true ]] && cleanup_history
