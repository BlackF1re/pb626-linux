# Mali‑400 / Lima на PocketBook 626 Plus ELAN/eMMC — 24 ноября 2026

Проверка выполнена на физической книге в экспериментальной ветке `experiment/lima-gles2` после загрузки через FEL в RAM.

- Ядро обнаружило Mali‑400 GP, PP0 и кэш L2. DRM зарегистрировал Lima 1.1.0 для `1c40000.gpu`.
- В проверке артефакта [45269406366](https://github.com/BlackF1re/pb626-linux/actions/runs/45269406366) Mesa инициализировала EGL 1.5. Значения `GL_RENDERER` и `GL_VERSION` были недоступны. Проверка `--verify-only` завершилась кодом 143 после таймаута. Аппаратное выполнение GLES2 и вывод сцены не подтверждены.
- При первом запуске GLES2 пропала USB-консоль. Причина не установлена.
- Диагностическая сборка [45270917913](https://github.com/BlackF1re/pb626-linux/actions/runs/45270917913) с коммитом `621bd4f` прошла Actions. Результат этой сборки на физической книге пока неизвестен.

```text
EGL 1.5 vendor=Mesa Project
GL_RENDERER=(unavailable)
GL_VERSION=(unavailable)
A hardware Mali-400 renderer is required
Terminated
GLES2 test exit=143
[drm] Initialized lima 1.1.0 for 1c40000.gpu on minor 0
```
