#!/bin/bash
#script by @dimagmd(@withoutusernamebtw)
set -euo pipefail

tput civis
trap 'tput cvvis' EXIT
clear

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
DARK_GRAY='\033[1;30m'
BOLD='\033[1m'
RESET='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${BOLD}Этому скрипту нужны права root для кастомизации GRUB${RESET}"
        echo -e "${YELLOW}Запустите через: sudo bash $0"
        exit 1
    fi
}

detect_distro() {
    FAMILY="unknown"
    DISTRO_ID="unknown"
    DISTRO_LIKE=""
    GRUB_CFG="/boot/grub/grub.cfg"
    GRUB_DEFAULT_FILE="/etc/default/grub"
    IS_BAZZITE=0
    IS_OSTREE=0

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    fi

    if [[ -f /run/ostree-booted ]]; then
        IS_OSTREE=1
    fi

    if [[ "$DISTRO_ID" == "bazzite" ]]; then
        IS_BAZZITE=1
        FAMILY="bazzite"
        GRUB_CFG="/boot/grub2/grub.cfg"
        GRUB_DEFAULT_FILE="/etc/default/grub"
    elif [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" || "$DISTRO_ID" == "linuxmint" || "$DISTRO_ID" == "pop" || "$DISTRO_LIKE" == *"debian"* || "$DISTRO_LIKE" == *"ubuntu"* ]]; then
        FAMILY="debian"
        GRUB_CFG="/boot/grub/grub.cfg"
        GRUB_DEFAULT_FILE="/etc/default/grub"
    elif [[ "$DISTRO_ID" =~ (fedora|rhel|centos|rocky|almalinux) || "$DISTRO_LIKE" == *"rhel"* || "$DISTRO_LIKE" == *"fedora"* ]]; then
        FAMILY="rhel"
        GRUB_CFG="/boot/grub2/grub.cfg"
        GRUB_DEFAULT_FILE="/etc/default/grub"
        [[ -f /etc/sysconfig/grub ]] && GRUB_DEFAULT_FILE="/etc/sysconfig/grub"
    elif [[ "$DISTRO_ID" == "arch" || "$DISTRO_LIKE" == *"arch"* ]]; then
        FAMILY="arch"
        GRUB_CFG="/boot/grub/grub.cfg"
        GRUB_DEFAULT_FILE="/etc/default/grub"
    fi

    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi
}

get_disk() {
    DISK=""
    local root_part=""
    local pk=""

    root_part=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ -n "$root_part" ]]; then
        pk=$(lsblk -no pkname "$root_part" 2>/dev/null | head -n1 || true)
    fi

    if [[ -z "$pk" ]]; then
        pk=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}' || true)
    fi

    if [[ -n "$pk" ]]; then
        if [[ -b "/dev/$pk" ]]; then
            DISK="/dev/$pk"
        fi
    fi
}

backup_grub() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/root/grub_backup_$ts"
    mkdir -p "$BACKUP_DIR"

    if [[ -f "$GRUB_DEFAULT_FILE" ]]; then
        cp -a "$GRUB_DEFAULT_FILE" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    if [[ -f "$GRUB_CFG" ]]; then
        cp -a "$GRUB_CFG" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    if [[ -d /etc/grub.d ]]; then
        cp -a /etc/grub.d "$BACKUP_DIR/" 2>/dev/null || true
    fi
    if [[ -f /boot/grub2/user.cfg ]]; then
        cp -a /boot/grub2/user.cfg "$BACKUP_DIR/" 2>/dev/null || true
    fi

    echo -e "${GREEN}Резервная копия сохранена: $BACKUP_DIR${RESET}"
}

set_grub_theme() {
    local theme_path="$1"
    local default_dir
    default_dir=$(dirname "$GRUB_DEFAULT_FILE")

    if [[ ! -d "$default_dir" ]]; then
        mkdir -p "$default_dir"
    fi

    if [[ ! -f "$GRUB_DEFAULT_FILE" ]]; then
        touch "$GRUB_DEFAULT_FILE"
    fi

    if grep -q '^GRUB_TERMINAL_OUTPUT=' "$GRUB_DEFAULT_FILE" 2>/dev/null; then
        sed -i 's|^GRUB_TERMINAL_OUTPUT=.*|GRUB_TERMINAL_OUTPUT="gfxterm"|' "$GRUB_DEFAULT_FILE"
    else
        echo 'GRUB_TERMINAL_OUTPUT="gfxterm"' >> "$GRUB_DEFAULT_FILE"
    fi

    if grep -q '^GRUB_THEME=' "$GRUB_DEFAULT_FILE" 2>/dev/null; then
        sed -i "s|^GRUB_THEME=.*|GRUB_THEME=\"$theme_path\"|" "$GRUB_DEFAULT_FILE"
    else
        echo "GRUB_THEME=\"$theme_path\"" >> "$GRUB_DEFAULT_FILE"
    fi
}

apply_grub() {
    echo -e "${YELLOW}Применение конфигурации GRUB...${RESET}"

    if [[ "$IS_BAZZITE" -eq 1 ]]; then
        if command -v ujust >/dev/null 2>&1; then
            ujust regenerate-grub
        else
            echo -e "${RED}ujust не найден. Пропускаю перегенерацию GRUB.${RESET}"
            return 1
        fi
    elif [[ "$FAMILY" == "debian" ]]; then
        if command -v update-grub >/dev/null 2>&1; then
            update-grub
        else
            grub-mkconfig -o "$GRUB_CFG"
        fi
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o "$GRUB_CFG"
    else
        grub-mkconfig -o "$GRUB_CFG"
    fi

    echo -e "${GREEN}Готово. Перезагрузитесь, чтобы увидеть тему.${RESET}"
}

install_theme_from_git() {
    local repo_url="$1"
    local theme_name="$2"
    local theme_dir="$3"
    local tmpdir=""

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    if ! git clone --depth=1 "$repo_url" "$tmpdir" 2>/dev/null; then
        echo -e "${RED}Не удалось склонировать $theme_name.${RESET}"
        return 1
    fi

    local theme_src=""
    theme_src=$(find "$tmpdir" -name "theme.txt" -printf '%h\n' 2>/dev/null | head -n1 || true)

    if [[ -z "$theme_src" ]]; then
        echo -e "${RED}Не удалось найти theme.txt в $theme_name.${RESET}"
        return 1
    fi

    mkdir -p "$theme_dir/$theme_name"
    cp -r "$theme_src"/* "$theme_dir/$theme_name/" 2>/dev/null || {
        echo -e "${RED}Ошибка копирования темы $theme_name.${RESET}"
        return 1
    }

    if [[ ! -f "$theme_dir/$theme_name/theme.txt" ]]; then
        echo -e "${RED}theme.txt не скопировался.${RESET}"
        return 1
    fi

    set_grub_theme "$theme_dir/$theme_name/theme.txt"
}

customize_grub() {
    detect_distro

    local theme_dir
    if [[ "$IS_BAZZITE" -eq 1 || "$FAMILY" == "rhel" ]]; then
        theme_dir="/boot/grub2/themes"
    else
        theme_dir="/boot/grub/themes"
    fi

    mkdir -p "$theme_dir" 2>/dev/null || true

    while true; do
        echo -e "${BOLD}═══════════════════════════════════════${RESET}"
        echo -e " ${GREEN}УСТАНОВКА ТЕМ GRUB (${DISTRO_ID:-?}, ${BOOT_MODE})${RESET}"
        echo -e "${BOLD}═══════════════════════════════════════${RESET}"
        echo -e " 1. HyperFluent"
        echo -e " 2. Tela"
        echo -e " 3. Vimix"
        echo -e " 4. Stylish"
        echo -e " 5. Вернуться в главное меню"
        echo -e "${BOLD}═══════════════════════════════════════${RESET}"
        read -r -p "Ваш выбор: " cch || exit 1

        case "$cch" in
            1)
                echo -e "${YELLOW}Установка HyperFluent...${RESET}"
                if install_theme_from_git "https://github.com/Coopydood/HyperFluent-GRUB-Theme.git" "hyperfluent" "$theme_dir"; then
                    apply_grub || true
                fi
                ;;
            2|3|4)
                local variant=""
                case "$cch" in
                    2) variant="tela" ;;
                    3) variant="vimix" ;;
                    4) variant="stylish" ;;
                esac
                echo -e "${YELLOW}Установка темы $variant...${RESET}"
                local tmpdir=""
                tmpdir=$(mktemp -d)
                if git clone --depth=1 https://github.com/vinceliuice/grub2-themes.git "$tmpdir" 2>/dev/null; then
                    local old_pwd="$PWD"
                    cd "$tmpdir" || { rm -rf "$tmpdir"; continue; }
                    if ./install.sh -t "$variant" -b 2>/dev/null; then
                        apply_grub || true
                    else
                        echo -e "${RED}Скрипт установки $variant завершился с ошибкой.${RESET}"
                    fi
                    cd "$old_pwd" || true
                else
                    echo -e "${RED}Не удалось склонировать grub2-themes.${RESET}"
                fi
                rm -rf "$tmpdir"
                ;;
            5)
                return
                ;;
            *)
                echo -e "${RED}Неверный выбор.${RESET}"
                sleep 1
                continue
                ;;
        esac
        read -r -p "Нажмите Enter для возврата в меню..." _ || true
    done
}

reset_grub() {
    detect_distro
    get_disk

    echo -e "${BOLD}═══════════════════════════════════════${RESET}"
    echo -e " ${RED}СБРОС GRUB ДО ЗАВОДСКИХ НАСТРОЕК"
    echo -e "${BOLD}═══════════════════════════════════════${RESET}"
    echo -e " ${YELLOW}Дистрибутив: ${DISTRO_ID} (${FAMILY})"
    echo -e " ${YELLOW}Режим загрузки: ${BOOT_MODE}"
    echo -e " ${YELLOW}Диск: ${DISK:-не определён}"
    echo
    echo -e "${RED}${BOLD}ВНИМАНИЕ:${RESET} ${RED}Все пользовательские настройки GRUB будут потеряны!${RESET}"
    read -r -p "Продолжить? (y/N): " confirm || exit 1

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}Отменено.${RESET}"
        read -r -p "Нажмите Enter для возврата в меню..." _ || true
        return
    fi

    backup_grub

    if [[ "$IS_BAZZITE" -eq 1 ]]; then
        echo -e "${YELLOW}Bazzite: сброс через ujust regenerate-grub...${RESET}"
        if [[ -f "$GRUB_DEFAULT_FILE" ]]; then
            mv "$GRUB_DEFAULT_FILE" "$GRUB_DEFAULT_FILE.bak.$(date +%s)" 2>/dev/null || true
        fi
        if command -v ujust >/dev/null 2>&1; then
            ujust regenerate-grub
        else
            echo -e "${RED}ujust не найден. Сброс не выполнен полностью.${RESET}"
        fi
        echo -e "${GREEN}${BOLD}Сброс GRUB выполнен!${RESET}"
        echo -e "${YELLOW}Резервная копия старых настроек: $BACKUP_DIR${RESET}"
        read -r -p "Нажмите Enter для возврата в меню..." _ || true
        return
    fi

    echo -e "${YELLOW}Удаление пользовательских конфигураций...${RESET}"
    local grubd_backup="$BACKUP_DIR/grub.d.removed"
    mkdir -p "$grubd_backup" 2>/dev/null || true

    for f in /etc/grub.d/40_custom /etc/grub.d/41_* /etc/grub.d/42_*; do
        [[ -f "$f" ]] && mv "$f" "$grubd_backup/" 2>/dev/null || true
    done

    case "$FAMILY" in
        debian)
            echo -e "${YELLOW}Переустановка пакетов GRUB...${RESET}"
            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                apt-get install --reinstall -y grub-efi-amd64 grub-common || true
            else
                apt-get install --reinstall -y grub-pc grub-common || true
            fi

            echo -e "${YELLOW}Восстановление загрузчика...${RESET}"
            local boot_id="${DISTRO_ID:-ubuntu}"
            if [[ "$boot_id" == "linuxmint" ]]; then
                boot_id="ubuntu"
            fi

            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$boot_id" --recheck || true
            else
                [[ -n "$DISK" ]] && grub-install --recheck "$DISK" || true
            fi

            echo -e "${YELLOW}Обновление конфигурации...${RESET}"
            if command -v update-grub >/dev/null 2>&1; then
                update-grub || true
            else
                grub-mkconfig -o "$GRUB_CFG" || true
            fi
            ;;
        rhel)
            echo -e "${YELLOW}Сохранение старых конфигов...${RESET}"
            local etc_backup="$BACKUP_DIR/etc_removed"
            mkdir -p "$etc_backup" 2>/dev/null || true

            if [[ -d /etc/grub.d ]]; then
                for f in /etc/grub.d/*; do
                    [[ -f "$f" ]] && mv "$f" "$etc_backup/" 2>/dev/null || true
                done
            fi
            [[ -f /etc/sysconfig/grub ]] && mv /etc/sysconfig/grub "$etc_backup/" 2>/dev/null || true
            [[ -f /etc/default/grub ]] && mv /etc/default/grub "$etc_backup/" 2>/dev/null || true

            echo -e "${YELLOW}Переустановка пакетов GRUB...${RESET}"
            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                if command -v dnf >/dev/null 2>&1; then
                    dnf reinstall -y grub2-efi-x64 shim-x64 grub2-tools grub2-common || true
                elif command -v yum >/dev/null 2>&1; then
                    yum reinstall -y grub2-efi shim grub2-tools grub2-common || true
                fi
            else
                if command -v dnf >/dev/null 2>&1; then
                    dnf reinstall -y grub2-tools || true
                elif command -v yum >/dev/null 2>&1; then
                    yum reinstall -y grub2-tools || true
                fi
            fi

            echo -e "${YELLOW}Восстановление загрузчика...${RESET}"
            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="${DISTRO_ID:-fedora}" --recheck || true
            else
                [[ -n "$DISK" ]] && grub2-install --recheck "$DISK" || true
            fi

            echo -e "${YELLOW}Генерация нового конфига...${RESET}"
            grub2-mkconfig -o "$GRUB_CFG" || true
            ;;
        arch)
            echo -e "${YELLOW}Переустановка GRUB...${RESET}"
            pacman -S --noconfirm grub || true
            if [[ "$BOOT_MODE" == "UEFI" ]]; then
                grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck || true
            else
                [[ -n "$DISK" ]] && grub-install --recheck "$DISK" || true
            fi
            grub-mkconfig -o "$GRUB_CFG" || true
            ;;
        *)
            echo -e "${RED}Неизвестный дистрибутив. Автоматический сброс невозможен.${RESET}"
            echo -e "${YELLOW}Выполните вручную: grub-install и grub-mkconfig/update-grub.${RESET}"
            ;;
    esac

    echo -e "${GREEN}${BOLD}Сброс GRUB выполнен!${RESET}"
    echo -e "${YELLOW}Резервная копия старых настроек: $BACKUP_DIR${RESET}"
    read -r -p "Нажмите Enter для возврата в меню..." _ || true
}

exit_script() {
    echo -e "${CYAN}${BOLD}До свидания! До новых встреч! Удачи с GRUB и Linux в будущем!${RESET}"
    exit 0
}

main_menu() {
    while true; do
        clear
        echo -e "${BOLD}═══════════════════════════════════════${RESET}"
        echo -e " ${GREEN}ГЛАВНОЕ МЕНЮ${RESET}"
        echo -e " ${RED}1. - Кастомизировать GRUB.${RESET}"
        echo -e " ${YELLOW}2. - Сбросить настройки и кастомизацию GRUB.${RESET}"
        echo -e " ${MAGENTA}3. - Выход из программы.${RESET}"
        echo -e "${BOLD}═══════════════════════════════════════${RESET}"
        read -r -p "Ваш выбор: " ch || exit 1

        case "$ch" in
            1) clear; customize_grub ;;
            2) clear; reset_grub ;;
            3) clear; exit_script ;;
            *) echo -e "${RED}Неверный выбор.${RESET}"; sleep 1 ;;
        esac
    done
}

check_root
detect_distro
main_menu