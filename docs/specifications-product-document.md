# Documento de Especificación de Producto: ParTUI

## 1. Visión General

**ParTUI** es un *wizard* interactivo basado en terminal (TUI) diseñado para automatizar y simplificar el flujo de particionado, formateo y montaje de unidades de almacenamiento en entornos UNIX-like.

Su propuesta de valor radica en la ejecución *standalone* (distribuible mediante `curl | bash` desde una URL remota), la ausencia de dependencias externas para su lógica de negocio, y la implementación de un flujo guiado por **Convención sobre Configuración** con divulgación progresiva, minimizando la carga cognitiva del usuario mediante *Sensible Defaults* conscientes del contexto del hardware.

## 2. Arquitectura y Modelo de Dominio

El script se estructura siguiendo principios de separación de responsabilidades, aislando la recolección de datos, la interfaz de usuario y la ejecución mutante del sistema operativo.

### 2.1. Entidades del Dominio (Contexto Estructurado)

Dado el entorno de ejecución (POSIX Shell), el estado se mantiene en memoria mediante variables simples y arrays indexados que modelan el dominio:

* **TargetDevice:** Representa el bloque físico (ej. `/dev/nvme0n1`, `/dev/sda`). Contiene metadatos de capacidad y tipo de bus.
* **PartitionLayout:** Esquema de particiones a aplicar (EFI, Swap, Root, Home, Custom).
* **ContextDictionary:** Almacena las decisiones de la máquina de estados, resolviendo dinámicamente la nomenclatura (ej. inyectando `p` para NVMe/Loop o un string vacío para SATA/SCSI antes del número de partición).

### 2.2. Capas del Sistema (Aproximación MVC)

* **Capa de Infraestructura (Lectura):** Wrappers puros sobre `lsblk -J` (o parseo de texto plano) y `/sys/block/` para hidratar el estado inicial.
* **Capa de Presentación (Vista):** Abstracción sobre `whiptail` (primera opción), con `dialog` y `select` como *fallback*. Funciones genéricas (`render_menu`, `render_input`, `render_msgbox`) que reciben el estado y devuelven el *input* del usuario.
* **Capa de Lógica (Controlador/FSM):** Máquina de estados finitos que evalúa las transiciones. Inyecta los *Sensible Defaults* si la presentación retorna nulo o *timeout*.
* **Capa de Ejecución (Mutación):** Funciones idempotentes y silenciosas que construyen comandos para `sgdisk/sfdisk`, `mkfs.*` y `mount` en base al estado final consolidado. Se ejecutan solo al final del flujo (transacción).

## 3. Especificación de Requisitos

### 3.1. Requisitos Funcionales (RF)

* **RF-01 (Detección):** El sistema debe identificar todos los dispositivos de bloques disponibles, excluyendo por defecto dispositivos *loop*, *rom*, *squashfs* y la partición donde reside el sistema actual (para evitar auto-destrucción).
* **RF-02 (Resolución Dinámica):** El sistema debe generar la nomenclatura de particiones correcta según el estándar del kernel (ej. `vda` → `vda1`; `nvme0n1` → `nvme0n1p1`).
* **RF-03 (Sensible Defaults):** Si el usuario omite una selección, el sistema aplicará un layout por defecto: Tabla GPT, Partición EFI (512M, vfat), Partición Swap (tamaño igual a RAM, máximo 8G), Partición Root (100% del espacio restante), FS `ext4`, Montaje en `/mnt`.
* **RF-04 (Divulgación Progresiva):** El menú inicial debe ofrecer únicamente la selección del disco y la opción "Usar configuración por defecto" vs "Personalizar topología".
* **RF-05 (Dry-Run / Confirmación):** Antes de aplicar cualquier mutación, el sistema debe presentar un resumen de las acciones destructivas y requerir confirmación explícita.
* **RF-06 (Soporte BTRFS):** El sistema debe permitir seleccionar BTRFS como sistema de archivos, incluyendo configuración de subvolúmenes (por defecto: `@`, `@home`, `@nix`, `@var`).
* **RF-07 (CLI Flags):** El sistema debe soportar ejecución no-interactiva mediante flags: `--disk`, `--esp-size`, `--swap-size`, `--root-size`, `--fs`, `--btrfs-subvols`, `--dry-run`, `--yes`.

### 3.2. Requisitos No Funcionales (RNF)

* **RNF-01 (Portabilidad POSIX):** El código debe ser 100% compatible con POSIX sh. Se evitarán extensiones Bash específicas (no usar `declare`, arrays asociativos, `[[ ]]`). Usar `#!/usr/bin/env sh` o `#!/bin/sh`.
* **RNF-02 (Dependencias Zero-Install):** La TUI debe basarse en utilidades presentes en la mayoría de Live CDs e imágenes mínimas: `whiptail` (primera opción), `dialog`, `select` como *fallback*. Todas las herramientas de particionado deben ser estándar (`sgdisk`/`sfdisk`, `lsblk`, `mkfs.*`, `mount`).
* **RNF-03 (Ejecución Segura):** El script debe abortar su ejecución tempranamente (`set -e`, `set -u`, `set -o pipefail`) si detecta la ausencia de herramientas críticas (`sgdisk`, `lsblk`, `mkfs.*`).
* **RNF-04 (Idempotencia en Fallos):** Si un proceso de formateo falla, el sistema debe detenerse y no intentar montar particiones inconsistentes. Debe limpiar estado parcial.
* **RNF-05 (Distribución URL):** El script debe poder instalarse con: `curl -fsSL <URL> | sudo bash -s -- [FLAGS]`

## 4. Diseño del Flujo de Interacción (FSM)

La máquina de estados finitos se compone de los siguientes nodos:

| Estado | Descripción | Transición Default (Enter/Timeout) | Transición Alternativa |
| --- | --- | --- | --- |
| **S0: Init** | Verificación de root, dependencias y parsing de CLI flags. | Avanza a S1 o S2 si hay flags completos. | Salida con error (Exit 1). |
| **S1: Select_Disk** | Lista de discos detectados. | Selecciona el disco de mayor capacidad. | El usuario selecciona un disco. |
| **S2: Choose_Path** | Prompt: ¿Por defecto o Custom? | Avanza a S5 (Aplica Defaults). | Avanza a S3 (Custom Layout). |
| **S3: Config_Layout** | Define tamaño/tipo de particiones. | Asigna 100% a Root (`/`). | Define particiones N múltiples. |
| **S4: Config_FS** | Define sistemas de archivos (`ext4`, `btrfs`). | Aplica `ext4` a particiones Linux. | Selecciona FS específico por partición. |
| **S4b: Config_BTRFS** | (Solo si FS=BTRFS) Define subvolúmenes. | Crea `@`, `@home`, `@nix`, `@var`. | Configuración personalizada. |
| **S5: Review** | Muestra el `ContextDictionary` final. | Confirma y avanza a S6. | Cancela y aborta o vuelve a S1. |
| **S6: Execute** | Ejecuta `sgdisk`, `mkfs`, `mount`. | Salida exitosa (Exit 0). | Muestra log de error de `stderr`. |

## 5. Estructura de Datos (Estado en Memoria)

Para implementar esto en POSIX sh (sin arrays asociativos), se usa convención de nomenclatura con prefijos:

```sh
# Variables del dispositivo objetivo
TARGET_DISK_PATH=""        # ej: /dev/nvme0n1
TARGET_DISK_MODEL=""       # ej: Samsung SSD 970
TARGET_DISK_SIZE=""        # ej: 512G
TARGET_DISK_PART_SUFFIX="" # ej: p (calculado dinámicamente)

# Variables de la topología a aplicar
LAYOUT_PART_COUNT=2
LAYOUT_PART1_TYPE="efi"
LAYOUT_PART1_SIZE="+512M"
LAYOUT_PART1_FS="vfat"
LAYOUT_PART1_MOUNT="/boot/efi"

LAYOUT_PART2_TYPE="linux"
LAYOUT_PART2_SIZE="+"     # Resto del disco
LAYOUT_PART2_FS="ext4"
LAYOUT_PART2_MOUNT="/"

# Variables BTRFS (solo si aplica)
BTRFS_SUBVOLS_ENABLED="false"
BTRFS_SUBVOL_COUNT=4
BTRFS_SUBVOL1="@"
BTRFS_SUBVOL2="@home"
BTRFS_SUBVOL3="@nix"
BTRFS_SUBVOL4="@var"
```

## 6. CLI Flags

El script debe soportar las siguientes flags:

| Flag | Descripción | Valor por defecto |
| --- | --- | --- |
| `--disk` | Dispositivo objetivo (ej. `/dev/sda`) | Interactivo |
| `--esp-size` | Tamaño partición EFI | `512M` |
| `--swap-size` | Tamaño swap | `2G` o igual a RAM |
| `--root-size` | Tamaño raíz (empty = resto) | Resto del disco |
| `--home-size` | Tamaño /home (optional) | Sin partición separada |
| `--fs` | Sistema de archivos | `ext4` |
| `--btrfs-subvols` | Lista de subvolúmenes BTRFS (comma-separated) | `@,@home,@nix,@var` |
| `--mount-point` | Punto de montaje base | `/mnt` |
| `--label` | Etiqueta para la partición root | `root` |
| `--dry-run` | Solo muestra comandos sin ejecutar | `false` |
| `-y, --yes` | Omite confirmación | `false` |
| `-h, --help` | Muestra ayuda | - |

## 7. Distribución

### Instalación vía curl

```bash
# Instalación directa (desde gist o raw URL)
curl -fsSL https://raw.githubusercontent.com/usuario/repo/main/partui.sh | sudo bash

# Con flags
curl -fsSL https://raw.githubusercontent.com/usuario/repo/main/partui.sh | sudo bash -s -- --disk /dev/sda --fs btrfs --yes

# Instalación local
curl -fsSL https://raw.githubusercontent.com/usuario/repo/main/partui.sh -o /tmp/partui.sh
chmod +x /tmp/partui.sh
sudo /tmp/partui.sh
```

### Verificación de integridad (opcional)

```bash
# Descargar con firma
curl -fsSL https://.../partui.sh | sudo bash -s -- --verify
```
