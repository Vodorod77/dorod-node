# 🚀 Установка ноды DOROD TECH

Нужно: **IP сервера** + **root-пароль** (от хостера) + **SECRET_KEY** (из панели: Nodes → создать ноду → «Copy docker-compose.yml» → строка `SECRET_KEY=...`).

Всё делается на сервере. Команды короткие — вставляются без проблем.

---

## Шаг 1 — зайти на сервер
```bash
ssh root@ВАШ_IP
```
Введите root-пароль.

---

## Шаг 2 — скачать установщик
```bash
curl -fsSL https://raw.githubusercontent.com/Vodorod77/dorod-node/main/dorod-node.sh -o node.sh
```

## Шаг 3 — запустить установку
```bash
bash node.sh install
```
Установщик **сам спросит** SECRET_KEY, IP панели и порт — вводите/вставляете по одному короткому значению. Длинные строки вставлять не надо.

✅ В конце: `контейнер: Up`, `NODE_PORT слушается`.

---

## Шаг 4 — добавить ноду в панель (браузер)
Nodes → **Add**: Address = `ВАШ_IP`, Port = тот что вводили (по умолч. `6767`), Config Profile = **тот же, что у других нод** → Create.

---

## Шаг 5 — проверить
```bash
bash node.sh doctor
```
🟢 **В СТРОЮ** — готово 🎉 · 🟠 **НЕ В СТРОЮ** — проверьте Шаг 4.

---

## Ещё сервер? Повторите Шаги 1–5. `SECRET_KEY` тот же.

## Если барахлит
```bash
bash node.sh doctor --apply        # осмотр + починка
docker logs remnanode --tail 30    # логи ноды
```

## Ошибки
| Ошибка | Фикс |
|--------|------|
| `Too many authentication failures` при входе | `ssh -o IdentitiesOnly=yes -i ~/.ssh/КЛЮЧ root@IP` |
| команда «обрубается» / виснет | не вставляйте длинные строки — Шаги 2–3 короткие |
| нода 🟠 не в строю | не добавлена в панель (Шаг 4) |

_by vodorod · Dorod Tech_
