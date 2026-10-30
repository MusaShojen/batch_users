# batch_users

Пакетные ключи для [xray-with-selfsni](https://github.com/ServerTechnologies/xray-with-selfsni): группы с префиксом, одна веб-страница на группу и раздача в один клик.

## Установка

На сервере, где уже установлен xray-with-selfsni:

```sh
wget -qO- https://raw.githubusercontent.com/MusaShojen/batch_users/refs/heads/main/batch-users.sh | bash
```

Или локально:

```sh
sudo bash batch-users.sh
```

## Команды

```sh
newkeys Orengo 10       # Orengo-001 … Orengo-010; повтор продолжит нумерацию
newkeys Orengo 5 qr     # то же, с QR в терминале
grouplinks              # список групп
grouplinks Orengo       # все ссылки группы
webshare Orengo         # одна страница на 24 часа
webshare Orengo 168     # на 168 часов
webshare Orengo 0       # без автоудаления
webshare Orengo off     # убрать страницу
rmgroup Orengo          # удалить группу и страницу
refreshpages            # пересобрать опубликованные страницы
```

У каждой группы **одна** веб-страница. Повторный `webshare` и `newkeys` не создают вторую ссылку — обновляется прежняя.

Логотип: `/usr/local/lib/xray-batch/brand/logo.png` (или `.svg` / `.jpg` / `.webp`).  
Файлы выгрузки: `/root/xray-export/<префикс>/`.
