# 🚀 Установка ноды DOROD TECH

Нужно всего три вещи:
- **IP сервера** (от хостера)
- **root-пароль** (от хостера)
- **SECRET_KEY** (из панели: Nodes → создать ноду → «Copy docker-compose.yml» → строка `SECRET_KEY=...`)

Ключи, SSH-config, имена — **не нужны**. Всё делается на самом сервере.

---

## Шаг 1 — зайти на сервер

```bash
ssh root@ВАШ_IP
```
Введите root-пароль от хостера.

---

## Шаг 2 — вставить ОДНУ команду

Подставьте свой `SECRET_KEY` и выполните **на сервере**:

```bash
SECRET_KEY='ВАШ_КЛЮЧ' PANEL_IP=IP_ПАНЕЛИ NODE_PORT=6767 LOCATION=de bash <(curl -fsSL https://raw.githubusercontent.com/Vodorod77/dorod-node/main/dorod-node.sh) install
```

Пойдёт установка (баннер DOROD TECH + 7 шагов).
✅ В конце: `контейнер: Up`, `NODE_PORT 6767 слушается`.

> `LOCATION=de` — метка (de/us/nl), можно менять или убрать.

---

## Шаг 3 — добавить ноду в панель (браузер)

Nodes → **Add**:
- Address = `ВАШ_IP`
- Port = `6767`
- Config Profile = **тот же, что у других нод**
- Create

---

## Шаг 4 — проверить

На сервере:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Vodorod77/dorod-node/main/dorod-node.sh) doctor
```
- 🟢 **В СТРОЮ** — готово 🎉
- 🟠 **НЕ В СТРОЮ** — проверьте Шаг 3

---

## Ещё сервер?
Повторите Шаги 1–4 на новом сервере. `SECRET_KEY` тот же.

## Если что-то барахлит (на сервере)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Vodorod77/dorod-node/main/dorod-node.sh) doctor --apply   # осмотр + починка
docker logs remnanode --tail 30                                             # логи ноды
```

_by vodorod · Dorod Tech_
