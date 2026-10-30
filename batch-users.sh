#!/bin/bash
# Дополнение к xray-with-selfsni: пакетный выпуск ключей с автоинкрементом.
# У каждой группы одна веб-страница: повторный webshare и newkeys обновляют её.
#
# Устанавливает команды:
#   newkeys <префикс> <кол-во>   — создать N ключей: Orengo-001, Orengo-002, ...
#   grouplinks <префикс>          — заново выгрузить ссылки и QR группы
#   webshare <префикс> [часы|0|off] — одна веб-страница с «Копировать» и QR
#   rmgroup <префикс>             — удалить всю группу ключей
#   refreshpages                  — пересобрать опубликованные страницы
#
# Установка:
#   wget -qO- https://raw.githubusercontent.com/MusaShojen/batch_users/refs/heads/main/batch-users.sh | bash
#   # или: sudo bash batch-users.sh

set -e
[ "$(id -u)" -eq 0 ] || { echo "Запустите от root"; exit 1; }

if [[ ! -f /usr/local/etc/xray/config.json ]]; then
    echo "Не найден /usr/local/etc/xray/config.json"
    echo "Сначала установите xray-with-selfsni, затем снова запустите этот скрипт."
    exit 1
fi

for p in jq qrencode zip at openssl; do
    command -v "$p" >/dev/null || apt install -y "$p"
done
systemctl enable --now atd 2>/dev/null || true

mkdir -p /usr/local/lib/xray-batch/brand
[ -f /usr/local/lib/xray-batch/brand/tagline.txt ] || echo 'Мы сделаем это возможным' > /usr/local/lib/xray-batch/brand/tagline.txt
[ -f /usr/local/lib/xray-batch/brand/logo.svg ] || cat << 'LOGO' > /usr/local/lib/xray-batch/brand/logo.svg
<svg xmlns="http://www.w3.org/2000/svg" width="248" height="64" viewBox="0 0 248 64" role="img" aria-label="CorTech">
  <style>
    .word{fill:#0f172a}
    .soft{fill:#0f172a;opacity:.72}
    @media (prefers-color-scheme: dark){.word{fill:#f8fafc}.soft{fill:#f8fafc;opacity:.78}}
  </style>
  <defs>
    <linearGradient id="g" x1="6" y1="6" x2="58" y2="58" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#22d3ee"/>
      <stop offset=".55" stop-color="#3b82f6"/>
      <stop offset="1" stop-color="#7c3aed"/>
    </linearGradient>
  </defs>
  <path d="M50.6 17.4A22 22 0 1 0 50.6 46.6" fill="none" stroke="url(#g)" stroke-width="7" stroke-linecap="round"/>
  <circle cx="32" cy="32" r="8.5" fill="url(#g)"/>
  <circle cx="53.5" cy="32" r="4" fill="#7c3aed"/>
  <path d="M40.5 32H49.5" stroke="url(#g)" stroke-width="3" stroke-linecap="round"/>
  <text x="72" y="42.5" font-family="-apple-system,'SF Pro Display','Segoe UI',Inter,Roboto,Helvetica,Arial,sans-serif" font-size="31" letter-spacing="-0.6">
    <tspan class="word" font-weight="800">Cor</tspan><tspan class="soft" font-weight="500">Tech</tspan>
  </text>
</svg>
LOGO
cat << 'EOF' > /usr/local/lib/xray-batch/common.sh
CONFIG=/usr/local/etc/xray/config.json
KEYS=/usr/local/etc/xray/.keys
EXPORT_DIR=/root/xray-export
WEB_ROOT=/var/www/html/s
STATE_DIR=/usr/local/etc/xray/webshares
BRAND_DIR=/usr/local/lib/xray-batch/brand

check_prefix() {
    if [[ ! "$1" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo "Префикс может содержать только латиницу, цифры и _ (без пробелов и дефисов)"
        exit 1
    fi
}

b64_file() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w0 "$1"
    else
        base64 -i "$1" 2>/dev/null | tr -d '\n'
    fi
}

file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

make_link() {
    local protocol port domain fp
    protocol=$(jq -r '.inbounds[0].protocol' "$CONFIG")
    port=$(jq -r '.inbounds[0].port' "$CONFIG")
    domain=$(awk -F': ' '/domain/ {print $2; exit}' "$KEYS")
    fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' "$CONFIG")
    echo "$protocol://$1@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=/&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$2"
}

brand_html() {
    local lf mime brand_mark
    brand_mark="<span class=\"wordmark\">CorTech</span>"
    for lf in "$BRAND_DIR"/logo.svg "$BRAND_DIR"/logo.png "$BRAND_DIR"/logo.jpg "$BRAND_DIR"/logo.webp; do
        if [[ -f "$lf" ]]; then
            case "$lf" in
                *.svg) mime=image/svg+xml ;;
                *.png) mime=image/png ;;
                *.jpg) mime=image/jpeg ;;
                *.webp) mime=image/webp ;;
            esac
            brand_mark="<img class=\"logo\" alt=\"CorTech\" src=\"data:$mime;base64,$(b64_file "$lf")\">"
            break
        fi
    done
    printf '%s' "$brand_mark"
}

list_share_dirs() {
    local prefix="$1" dir nullglob_was=0
    [[ -d "$WEB_ROOT" ]] || return 0
    shopt -q nullglob && nullglob_was=1
    shopt -s nullglob
    for dir in "$WEB_ROOT"/*; do
        [[ -f "$dir/.group" ]] || continue
        [[ "$(<"$dir/.group")" == "$prefix" ]] && printf '%s\n' "$dir"
    done
    (( nullglob_was )) || shopt -u nullglob
    return 0
}

# Одна директория на префикс. Если их несколько — лишние удаляются.
# Уже известная ссылка (файл состояния) сохраняется.
single_share_dir() {
    local prefix="$1"
    local state="$STATE_DIR/$prefix" token="" kept="" d m best_m=-1
    local -a dirs=()
    mapfile -t dirs < <(list_share_dirs "$prefix")

    if [[ -f "$state" ]]; then
        token=$(<"$state")
        if [[ -n "$token" && -f "$WEB_ROOT/$token/.group" && "$(<"$WEB_ROOT/$token/.group")" == "$prefix" ]]; then
            kept="$WEB_ROOT/$token"
        fi
    fi

    if [[ -z "$kept" ]]; then
        for d in "${dirs[@]}"; do
            [[ -z "$d" || ! -d "$d" ]] && continue
            m=$(file_mtime "$d")
            if (( m >= best_m )); then
                best_m=$m
                kept=$d
            fi
        done
    fi

    for d in "${dirs[@]}"; do
        [[ -z "$d" || -z "$kept" || "$d" == "$kept" ]] && continue
        rm -rf "$d"
        echo "Удалена лишняя страница группы $prefix" >&2
    done

    if [[ -z "$kept" ]]; then
        rm -f "$state"
        return 0
    fi

    mkdir -p "$STATE_DIR"
    printf '%s\n' "${kept##*/}" > "$state"
    printf '%s\n' "$kept"
}

published_url() {
    local prefix="$1" token domain
    [[ -f "$STATE_DIR/$prefix" ]] || return 1
    token=$(<"$STATE_DIR/$prefix")
    [[ -n "$token" && -f "$WEB_ROOT/$token/index.html" ]] || return 1
    domain=$(awk -F': ' '/domain/ {print $2; exit}' "$KEYS")
    [[ -n "$domain" ]] || return 1
    printf 'https://%s/s/%s/\n' "$domain" "$token"
}

group_count() {
    local n
    [[ -f "$CONFIG" ]] || return 1
    if ! n=$(jq --arg p "$1" '[.inbounds[0].settings.clients[] | select(.email | test("^" + $p + "-[0-9]+$"))] | length' "$CONFIG" 2>/dev/null); then
        return 1
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$n"
}

write_empty_page() {
    local prefix="$1" dir="$2" brand_mark tagline
    brand_mark=$(brand_html)
    tagline=$(cat "$BRAND_DIR/tagline.txt" 2>/dev/null || echo "Мы сделаем это возможным")
    cat > "$dir/index.html" << EMPTY_PAGE
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Ключи $prefix</title>
<style>
:root{--bg:#f5f5f4;--card:#fff;--text:#1c1917;--muted:#78716c;--line:#e7e5e4}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--card:#292524;--text:#fafaf9;--muted:#a8a29e;--line:#44403c}}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.4 -apple-system,system-ui,sans-serif;padding:16px}
.brand{max-width:1100px;margin:8px auto 20px;display:flex;flex-direction:column;align-items:center;gap:6px;text-align:center}
.logo{max-height:56px;max-width:220px;width:auto;height:auto}
.wordmark{font-size:28px;font-weight:800;letter-spacing:-.02em}
.tagline{margin:0;color:var(--muted);font-size:15px}
.box{max-width:640px;margin:0 auto;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px}
h1{font-size:20px;margin:0 0 8px}
p{margin:0;color:var(--muted)}
</style></head><body>
<div class="brand">$brand_mark<p class="tagline">$tagline</p></div>
<div class="box"><h1>$prefix</h1><p>В этой группе пока нет ключей. Когда ключи добавят, эта же ссылка откроет обновлённый список.</p></div>
</body></html>
EMPTY_PAGE
}

export_group() {
    local prefix="$1" dir="$EXPORT_DIR/$1"
    local clients cards="" count=0 name uuid link b64 brand_mark tagline
    clients=$(jq -r --arg p "$prefix" '.inbounds[0].settings.clients[]
        | select(.email | test("^" + $p + "-[0-9]+$")) | "\(.email) \(.id)"' "$CONFIG" | sort -t- -k2 -n) || true
    if [[ -z "$clients" ]]; then
        echo "Ключей с префиксом $prefix не найдено" >&2
        return 1
    fi

    rm -rf "$dir"
    mkdir -p "$dir/qr"
    while read -r name uuid; do
        link=$(make_link "$uuid" "$name")
        echo "$name  $link" >> "$dir/links.txt"
        echo "$link" >> "$dir/links-only.txt"
        qrencode -t PNG -s 8 -m 2 -o "$dir/qr/$name.png" "$link"
        b64=$(b64_file "$dir/qr/$name.png")
        cards+="<div class=\"card\" data-n=\"$((10#${name##*-}))\"><h2>$name</h2><div class=\"qr\"><img alt=\"QR $name\" src=\"data:image/png;base64,$b64\"></div>
<textarea readonly>$link</textarea>
<button onclick=\"copy(this)\">Копировать ссылку</button></div>"
        count=$((count+1))
    done <<< "$clients"

    brand_mark=$(brand_html)
    tagline=$(cat "$BRAND_DIR/tagline.txt" 2>/dev/null || echo "Мы сделаем это возможным")
    cat > "$dir/index.html" << PAGE_HTML
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Ключи $prefix</title>
<style>
:root{--bg:#f5f5f4;--card:#fff;--text:#1c1917;--muted:#78716c;--accent:#1c1917;--line:#e7e5e4}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--card:#292524;--text:#fafaf9;--muted:#a8a29e;--accent:#fafaf9;--line:#44403c}}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.4 -apple-system,system-ui,sans-serif;padding:16px}
header{max-width:1100px;margin:0 auto 16px;display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between}
h1{font-size:20px;margin:0}
.brand{max-width:1100px;margin:8px auto 20px;display:flex;flex-direction:column;align-items:center;gap:6px;text-align:center}
.logo{max-height:56px;max-width:220px;width:auto;height:auto}
.wordmark{font-size:28px;font-weight:800;letter-spacing:-.02em}
.tagline{margin:0;color:var(--muted);font-size:15px}
.grid{max-width:1100px;margin:0 auto;display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;display:flex;flex-direction:column;gap:10px}
.card h2{font-size:16px;margin:0}
.tools{display:flex;gap:8px;flex-wrap:wrap;flex:1;justify-content:flex-end}
#q{flex:1;min-width:180px;max-width:320px;font:inherit;padding:9px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text)}
#empty{max-width:1100px;margin:0 auto 12px;color:var(--muted)}
.card[hidden]{display:none}
.card.exact{outline:2px solid var(--accent)}
.qr{background:#fff;border-radius:8px;padding:8px}.qr img{width:100%;height:auto;display:block;image-rendering:pixelated}
textarea{font:11px ui-monospace,monospace;height:52px;resize:none;border:1px solid var(--line);border-radius:6px;background:transparent;color:var(--muted);padding:6px}
button{border:0;border-radius:8px;padding:10px;font:inherit;font-weight:600;background:var(--accent);color:var(--bg);cursor:pointer}
button.done{opacity:.6}
</style></head><body>
<div class="brand">$brand_mark<p class="tagline">$tagline</p></div>
<header><h1>$prefix — $count ключей</h1><div class="tools"><input id="q" type="search" inputmode="numeric" placeholder="Номер ключа, например 17" autocomplete="off"><button id="all" onclick="copyAll(this)">Копировать все ссылки</button></div></header>
<p id="empty" hidden>Ключ с таким номером не найден</p>
<div class="grid">$cards</div>
<script>
function put(t,b,l){navigator.clipboard.writeText(t).then(()=>{const o=b.textContent;b.textContent=l;b.classList.add('done');setTimeout(()=>{b.textContent=o;b.classList.remove('done')},1500)}).catch(()=>{})}
function copy(b){const t=b.previousElementSibling;t.select();put(t.value,b,'Скопировано ✓')}
function copyAll(b){put([...document.querySelectorAll('.card:not([hidden]) textarea')].map(t=>t.value).join('\n'),b,'Скопировано ✓')}
const q=document.getElementById('q'),cards=[...document.querySelectorAll('.card')],all=document.getElementById('all'),empty=document.getElementById('empty');
q.addEventListener('input',()=>{const v=q.value.replace(/\D/g,'').replace(/^0+(?=\d)/,'');let shown=0;
for(const c of cards){const ok=!v||c.dataset.n===v||c.dataset.n.startsWith(v);c.hidden=!ok;if(ok)shown++}
cards.forEach(c=>c.classList.toggle('exact',v&&c.dataset.n===v));
all.textContent=v?'Копировать найденные ('+shown+')':'Копировать все ссылки';empty.hidden=shown>0;
const ex=cards.find(c=>c.dataset.n===v);if(ex)ex.scrollIntoView({block:'nearest'})});
</script></body></html>
PAGE_HTML
    (cd "$EXPORT_DIR" && rm -f "$prefix.zip" && command -v zip >/dev/null && zip -qr "$prefix.zip" "$prefix") || true
    echo "$count"
}

# Обновить уже опубликованную страницу. Ничего не создаёт.
# Печатает URL, если страница есть. Пустой вывод — страницы не было.
refresh_share_page() {
    local prefix="$1" reuse="${2:-}" dir count
    dir=$(single_share_dir "$prefix")
    [[ -n "$dir" ]] || return 0
    if ! count=$(group_count "$prefix"); then
        return 1
    fi
    if (( count == 0 )); then
        write_empty_page "$prefix" "$dir" || return 1
    else
        if [[ "$reuse" != "reuse" ]]; then
            export_group "$prefix" >/dev/null || return 1
        fi
        [[ -f "$EXPORT_DIR/$prefix/index.html" ]] || return 1
        cp "$EXPORT_DIR/$prefix/index.html" "$dir/index.html" || return 1
    fi
    chmod -R a+rX "$WEB_ROOT" || true
    published_url "$prefix"
}

remove_share() {
    local prefix="$1" d token
    while IFS= read -r d; do
        [[ -n "$d" ]] && rm -rf "$d"
    done < <(list_share_dirs "$prefix")
    if [[ -f "$STATE_DIR/$prefix" ]]; then
        token=$(<"$STATE_DIR/$prefix")
        [[ -n "$token" ]] && rm -rf "$WEB_ROOT/$token"
        rm -f "$STATE_DIR/$prefix"
    fi
}

# Создать страницу, только если её ещё нет. Иначе обновить файлы на месте.
open_share() {
    local prefix="$1" hours="$2" dir token
    mkdir -p "$WEB_ROOT" "$STATE_DIR"
    dir=$(single_share_dir "$prefix")
    export_group "$prefix" >/dev/null || return 1
    if [[ -z "$dir" ]]; then
        token=$(openssl rand -hex 16)
        dir="$WEB_ROOT/$token"
        mkdir -p "$dir" || return 1
        printf '%s\n' "$prefix" > "$dir/.group"
        printf '%s\n' "$token" > "$STATE_DIR/$prefix"
        cp "$EXPORT_DIR/$prefix/index.html" "$dir/index.html" || return 1
        if (( hours == 0 )); then
            echo 0 > "$dir/.hours"
        elif echo "rm -rf '$dir' '$STATE_DIR/$prefix'" | at now + "$hours" hours 2>/dev/null; then
            echo "$hours" > "$dir/.hours"
        else
            echo fail > "$dir/.hours"
        fi
    else
        cp "$EXPORT_DIR/$prefix/index.html" "$dir/index.html" || return 1
    fi
    chmod -R a+rX "$WEB_ROOT" || true
    published_url "$prefix"
}
EOF
cat << 'EOF' > /usr/local/bin/newkeys
#!/bin/bash
source /usr/local/lib/xray-batch/common.sh
prefix="$1"; count="$2"; showqr="$3"
if [[ -z "$prefix" || -z "$count" ]]; then
    echo "Использование: newkeys <префикс> <количество> [qr]"
    echo "Пример: newkeys Orengo 10"
    exit 1
fi
check_prefix "$prefix"
[[ "$count" =~ ^[0-9]+$ ]] || { echo "Количество: от 1 до 500"; exit 1; }
count=$((10#$count))
(( count >= 1 && count <= 500 )) || { echo "Количество: от 1 до 500"; exit 1; }

last=$(jq -r --arg p "$prefix" '[.inbounds[0].settings.clients[].email
    | select(test("^" + $p + "-[0-9]+$")) | ltrimstr($p + "-") | tonumber] | max // 0' "$CONFIG")

cp "$CONFIG" "$CONFIG.bak"
new_clients="[]"
names=()
for ((i=1; i<=count; i++)); do
    num=$((last + i))
    name=$(printf "%s-%03d" "$prefix" "$num")
    new_clients=$(jq --arg e "$name" --arg id "$(xray uuid)" \
        '. + [{"email":$e,"id":$id,"flow":"xtls-rprx-vision","level":0}]' <<< "$new_clients")
    names+=("$name")
done

tmp=$(mktemp)
if ! jq --argjson n "$new_clients" '.inbounds[0].settings.clients += $n' "$CONFIG" > "$tmp"; then
    rm -f "$tmp"
    echo "Не удалось записать конфиг"
    exit 1
fi
mv "$tmp" "$CONFIG"
chmod 644 "$CONFIG"

if ! xray run -test -config "$CONFIG" >/dev/null 2>&1; then
    mv "$CONFIG.bak" "$CONFIG"
    chmod 644 "$CONFIG"
    echo "Ошибка в конфиге, изменения отменены"
    exit 1
fi
systemctl restart xray

echo ""
echo "Создано ключей: $count  (${names[0]} … ${names[-1]})"
echo ""
for name in "${names[@]}"; do
    uuid=$(jq -r --arg e "$name" '.inbounds[0].settings.clients[] | select(.email==$e) | .id' "$CONFIG")
    link=$(make_link "$uuid" "$name")
    echo "$name"
    echo "$link"
    [[ "$showqr" == "qr" ]] && qrencode -t ansiutf8 "$link"
    echo ""
done

total=$(export_group "$prefix") || exit 1
echo "Всего в группе $prefix: $total. Файлы: $EXPORT_DIR/$prefix/"
if page_url=$(refresh_share_page "$prefix" reuse); then
    if [[ -n "$page_url" ]]; then
        echo "Веб-страница обновлена, ссылка прежняя:"
        echo "$page_url"
    else
        echo "Одна страница на группу: webshare $prefix"
    fi
else
    echo "Не удалось обновить веб-страницу группы $prefix"
fi
EOF
cat << 'EOF' > /usr/local/bin/grouplinks
#!/bin/bash
source /usr/local/lib/xray-batch/common.sh
prefix="$1"
if [[ -z "$prefix" ]]; then
    echo "Использование: grouplinks <префикс>"
    echo "Группы:"
    jq -r '.inbounds[0].settings.clients[].email | select(test("-[0-9]+$")) | sub("-[0-9]+$";"")' "$CONFIG" \
        | sort | uniq -c | awk '{print "  "$2" — "$1" шт."}'
    exit 1
fi
check_prefix "$prefix"
total=$(export_group "$prefix") || exit 1
cat "$EXPORT_DIR/$prefix/links.txt"
echo ""
echo "Ключей: $total. Файлы: $EXPORT_DIR/$prefix/ (links.txt, qr/*.png, index.html)"
if page_url=$(refresh_share_page "$prefix" reuse); then
    if [[ -n "$page_url" ]]; then
        echo "Веб-страница обновлена, ссылка прежняя:"
        echo "$page_url"
    fi
else
    echo "Не удалось обновить веб-страницу группы $prefix"
fi
EOF
cat << 'EOF' > /usr/local/bin/webshare
#!/bin/bash
source /usr/local/lib/xray-batch/common.sh
prefix="$1"
action="$2"
if [[ -z "$prefix" ]]; then
    echo "Использование: webshare <префикс> [часы|0|off]"
    echo "  webshare Orengo       — одна страница на 24 часа"
    echo "  webshare Orengo 168    — на 168 часов"
    echo "  webshare Orengo 0      — без автоудаления"
    echo "  webshare Orengo off    — убрать страницу"
    echo "Повторный запуск обновляет ту же страницу и не создаёт вторую."
    exit 1
fi
check_prefix "$prefix"
if [[ "$action" == "off" ]]; then
    remove_share "$prefix"
    echo "Страница $prefix удалена"
    exit 0
fi
hours="${action:-24}"
if [[ ! "$hours" =~ ^[0-9]+$ ]]; then
    echo "Срок — число часов, 0 = бессрочно, off = удалить"
    exit 1
fi
hours=$((10#$hours))
existed=$(single_share_dir "$prefix")
url=$(open_share "$prefix" "$hours") || exit 1
echo ""
if [[ -n "$existed" ]]; then
    echo "Страница группы $prefix уже есть — вторая не создана."
    echo "Ключи на ней обновлены, ссылка прежняя:"
else
    echo "Страница группы $prefix:"
fi
echo "$url"
echo ""
if [[ -z "$existed" ]]; then
    token=$(<"$STATE_DIR/$prefix")
    scheduled=$(<"$WEB_ROOT/$token/.hours")
    if [[ "$scheduled" == "fail" ]]; then
        echo "Не удалось запланировать удаление. Убрать страницу: webshare $prefix off"
    elif [[ "$scheduled" == "0" ]]; then
        echo "Автоудаление не задано. Убрать страницу: webshare $prefix off"
    else
        echo "Удалится автоматически через ${scheduled} ч. Повторный webshare эту ссылку не меняет."
    fi
else
    echo "Новые ключи (newkeys) попадут на эту же страницу сами."
fi
EOF
cat << 'EOF' > /usr/local/bin/rmgroup
#!/bin/bash
source /usr/local/lib/xray-batch/common.sh
prefix="$1"
[[ -z "$prefix" ]] && { echo "Использование: rmgroup <префикс>"; exit 1; }
check_prefix "$prefix"
n=$(jq --arg p "$prefix" '[.inbounds[0].settings.clients[] | select(.email | test("^" + $p + "-[0-9]+$"))] | length' "$CONFIG")
(( n == 0 )) && { echo "Группа $prefix не найдена"; exit 1; }
read -p "Удалить $n ключей группы $prefix? Напишите yes: " ok
[[ "$ok" == "yes" ]] || { echo "Отменено"; exit 0; }
cp "$CONFIG" "$CONFIG.bak"
tmp=$(mktemp)
if ! jq --arg p "$prefix" '.inbounds[0].settings.clients |= map(select(.email | test("^" + $p + "-[0-9]+$") | not))' "$CONFIG" > "$tmp"; then
    rm -f "$tmp"
    echo "Не удалось записать конфиг"
    exit 1
fi
mv "$tmp" "$CONFIG"
chmod 644 "$CONFIG"
systemctl restart xray
remove_share "$prefix"
rm -rf "$EXPORT_DIR/$prefix" "$EXPORT_DIR/$prefix.zip"
echo "Группа $prefix удалена ($n ключей), веб-страница тоже"
EOF
cat << 'EOF' > /usr/local/bin/refreshpages
#!/bin/bash
source /usr/local/lib/xray-batch/common.sh
found=0
declare -A seen=()
shopt -s nullglob
for d in "$WEB_ROOT"/*; do
    [[ -f "$d/.group" ]] || continue
    g=$(<"$d/.group")
    [[ "$g" =~ ^[A-Za-z0-9_]+$ ]] || continue
    seen["$g"]=1
done
shopt -u nullglob
for g in "${!seen[@]}"; do
    found=1
    if page_url=$(refresh_share_page "$g"); then
        if [[ -n "$page_url" ]]; then
            echo "$g — страница обновлена: $page_url"
        fi
    else
        echo "$g — не удалось обновить страницу"
    fi
done
if (( found == 0 )); then
    echo "Опубликованных страниц нет"
fi
EOF
chmod +x /usr/local/bin/newkeys /usr/local/bin/grouplinks /usr/local/bin/webshare /usr/local/bin/rmgroup /usr/local/bin/refreshpages

# Хуки: после newuser/rmuser обновлять страницу группы, если имя вида Prefix-001
install_refresh_hook() {
    local bin="$1" marker="$2" hook_file="$3"
    [[ -f "$bin" ]] || return 0
    grep -q 'refresh_share_page' "$bin" 2>/dev/null && return 0
    grep -qF "$marker" "$bin" || return 0
    local tmp; tmp=$(mktemp)
    awk -v marker="$marker" -v hook="$hook_file" '
        index($0, marker) {
            print
            while ((getline line < hook) > 0) print line
            close(hook)
            next
        }
        { print }
    ' "$bin" > "$tmp" && mv "$tmp" "$bin"
    chmod +x "$bin"
}

cat << 'HOOK' > /tmp/xray-batch-newuser.hook
if [[ "$email" =~ ^([A-Za-z0-9_]+)-[0-9]+$ ]] && [[ -f /usr/local/lib/xray-batch/common.sh ]]; then
  source /usr/local/lib/xray-batch/common.sh
  page_url=$(refresh_share_page "${BASH_REMATCH[1]}") || true
  if [[ -n "$page_url" ]]; then
    echo ""
    echo "Веб-страница группы обновлена, ссылка прежняя:"
    echo "$page_url"
  fi
fi
HOOK

cat << 'HOOK' > /tmp/xray-batch-rmuser.hook
if [[ "$selected_email" =~ ^([A-Za-z0-9_]+)-[0-9]+$ ]] && [[ -f /usr/local/lib/xray-batch/common.sh ]]; then
  source /usr/local/lib/xray-batch/common.sh
  page_url=$(refresh_share_page "${BASH_REMATCH[1]}") || true
  if [[ -n "$page_url" ]]; then
    echo "Веб-страница группы обновлена, ссылка прежняя:"
    echo "$page_url"
  fi
fi
HOOK

install_refresh_hook /usr/local/bin/newuser 'qrencode -t ansiutf8' /tmp/xray-batch-newuser.hook
install_refresh_hook /usr/local/bin/rmuser 'удалён.' /tmp/xray-batch-rmuser.hook
rm -f /tmp/xray-batch-newuser.hook /tmp/xray-batch-rmuser.hook

HELP_FILE="${HOME}/help"
touch "$HELP_FILE"
if ! grep -q 'newkeys ' "$HELP_FILE" 2>/dev/null; then
cat << 'EOF' >> "$HELP_FILE"

Пакетные ключи. На каждую группу приходится одна веб-страница:

    newkeys Orengo 10    - создать 10 ключей Orengo-001…010 (повтор продолжит нумерацию)
    newkeys Orengo 5 qr  - то же, с QR-кодами в терминале
    grouplinks           - список групп
    grouplinks Orengo    - ссылки группы; опубликованная страница обновляется
    webshare Orengo      - страница с QR и кнопками «Копировать» на 24 часа
    webshare Orengo 168  - на 168 часов; 0 — без автоудаления
    webshare Orengo off  - убрать страницу
    Повторный webshare и добавление ключей не создают вторую страницу: обновляется прежняя ссылка
    rmgroup Orengo       - удалить всю группу и её страницу
    refreshpages         - заново собрать все опубликованные страницы
    Логотип: /usr/local/lib/xray-batch/brand/logo.png (или .svg / .jpg / .webp)
    Файлы выгрузки: /root/xray-export/<префикс>/
EOF
fi

# Закрыть скрытые файлы (.group, .hours). Важно: в awk нужен /\\., иначе получится "/." и nginx отдаст 403 на весь сайт.
if [[ -f /etc/nginx/sites-available/default ]]; then
    if grep -qE 'location[[:space:]]+~[[:space:]]+/\.[[:space:]]*\{[[:space:]]*deny all' /etc/nginx/sites-available/default; then
        # уже было сломано установщиком — чиним
        sed -i -E 's|location[[:space:]]+~[[:space:]]+/\.[[:space:]]*\{[[:space:]]*deny all;[[:space:]]*\}|location ~ /\\. { deny all; }|' /etc/nginx/sites-available/default
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    elif ! grep -qE 'location[[:space:]]+~[[:space:]]+/\\.' /etc/nginx/sites-available/default; then
        tmp=$(mktemp)
        awk '
            /add_header Strict-Transport-Security/ {
                print
                print "        autoindex off;"
                print "        location ^~ /.well-known/ { }"
                print "        location ~ /\\. { deny all; }"
                next
            }
            { print }
        ' /etc/nginx/sites-available/default > "$tmp" && mv "$tmp" /etc/nginx/sites-available/default
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
fi

refreshpages >/dev/null 2>&1 || true
echo "Готово. Команды: newkeys, grouplinks, webshare, rmgroup, refreshpages"
echo "У каждой группы одна веб-страница: повторный webshare обновляет прежнюю ссылку."
